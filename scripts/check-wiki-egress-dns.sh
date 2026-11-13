#!/usr/bin/env bash
#
# Fail when the OIDC issuer host in k8s/apps/wiki/values.yaml resolves to an
# address outside the CIDRs listed in oidc.egressCidrs of that same file.
#
#   ./scripts/check-wiki-egress-dns.sh
#
# The wiki NetworkPolicy allows the BookStack pod egress on 443 only to those
# CIDRs, and the pod reaches <issuer>/.well-known/openid-configuration through
# them. When the Pangolin edge address moves, the discovery request is dropped,
# no login ever completes, and every pod still reports Ready — nothing else in
# this repo connects the DNS answer to the list.
#
# Vantage: this resolves through the public DNS of wherever it runs (in CI, a
# GitHub-hosted runner). That is the vantage that sees the public edge address,
# which is what the /32 in values.yaml records. It is NOT the vantage of the
# pod inside the cluster; once CoreDNS split-horizon lands (canonical-URLs
# phase 0), the in-cluster answer may legitimately differ from this one, and
# this job still asserts the public answer only.
#
# Semantics of the lookup, because "no answer" and "wrong answer" are not the
# same event and neither may read as a pass:
#   - resolver error (SERVFAIL, timeout, no reachable server): FAIL.
#   - name resolves to no IPv4 A record (NXDOMAIN, NODATA, or only non-A
#     answers): FAIL. An unresolvable name drops the discovery request exactly
#     like a blocked one.
#   - several A records: EVERY address must fall inside SOME CIDR. The pod's
#     resolver may return any of them in any order, so one allowed address
#     among them is not evidence the pod can reach the issuer.
#   - every address inside some CIDR: PASS.
#
# What a green run does NOT claim:
#   - that the discovery endpoint answers, only that the route to it is open.
#   - anything about AAAA records: the egress list is IPv4-only, so this is
#     IPv4-only; an AAAA-only edge would need the policy reworked, not this
#     check extended.
#   - the in-cluster view of the name (see Vantage above).
set -euo pipefail

# `CDPATH= cd` is a prefix assignment, not an empty one: CDPATH must not redirect this.
# shellcheck disable=SC1007
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

values_file=k8s/apps/wiki/values.yaml
[ -f "$values_file" ] || {
  echo "::error::$values_file is missing, so neither the issuer nor the CIDR list can be read" >&2
  exit 1
}

# A top-level key opens a block and any deeper key of that name belongs to it —
# same shape as check-wiki-invariants.sh: a duplicated key must not silently
# first-match-win while Helm reads the last one.
values_get() { # $1 = dotted two-part key
  local top=${1%%.*} leaf=${1#*.}
  awk -v top="$top" -v leaf="$leaf" '
    /^[A-Za-z0-9_-]+:/ {
      t = $0
      sub(/:.*$/, "", t)
      inblock = (t == top)
      next
    }
    inblock && $0 ~ "^[[:space:]]+" leaf ":" {
      v = $0
      sub(/^[[:space:]]*[^:]*:[[:space:]]*/, "", v)
      sub(/[[:space:]]*(#.*)?$/, "", v)
      gsub(/^"|"$/, "", v)
      print v
    }
  ' "$values_file"
}

# The list items under oidc.egressCidrs, one per line. Read from the file on
# purpose: when split-horizon DNS lands the list changes shape, and a copy of
# it here would check the check instead of the policy.
egress_cidrs_get() {
  awk '
    /^[A-Za-z0-9_-]+:/ { inblock = ($0 ~ /^oidc:/); next }
    inblock && /^[[:space:]]+egressCidrs:[[:space:]]*(#.*)?$/ { incom = 1; next }
    incom && /^[[:space:]]*#/ { next }
    incom && /^[[:space:]]*-[[:space:]]*[^[:space:]]/ {
      v = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", v)
      sub(/[[:space:]]*(#.*)?$/, "", v)
      gsub(/^"|"$/, "", v)
      print v
      next
    }
    incom && $0 ~ /[^[:space:]]/ { incom = 0 }
  ' "$values_file"
}

issuer=$(values_get oidc.issuer)
if [ -z "$issuer" ]; then
  echo "::error::oidc.issuer not found in $values_file; the check cannot know which name to resolve" >&2
  exit 1
fi
# Strip scheme and path; the issuer is a base URL, the A record belongs to its host.
host=$(printf '%s' "$issuer" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://##; s#[/?:].*$##')

mapfile -t cidrs < <(egress_cidrs_get)
if [ "${#cidrs[@]}" -eq 0 ]; then
  echo "::error::oidc.egressCidrs in $values_file lists no CIDR. The chart refuses to render an empty list because a policy rule with no peer matches every destination; a check that read nothing here would pass on the widest possible policy." >&2
  exit 1
fi

ip2int() { # $1 = dotted quad; echoes the 32-bit value, returns 1 if malformed
  local ip=$1 a b c d
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]} c=${BASH_REMATCH[3]} d=${BASH_REMATCH[4]}
  ((a <= 255 && b <= 255 && c <= 255 && d <= 255)) || return 1
  printf '%s' $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

in_cidr() { # $1 = IPv4 dotted quad, $2 = CIDR in a.b.c.d/n form
  local net=${2%%/*} bits=${2##*/} n ip mask
  [[ $bits =~ ^([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
  n=$(ip2int "$net") || return 1
  ip=$(ip2int "$1") || return 1
  if ((bits == 0)); then mask=0; else mask=$(( (4294967295 << (32 - bits)) & 4294967295 )); fi
  (( (ip & mask) == (n & mask) ))
}

# Every CIDR in the file must be a parseable a.b.c.d/n. A malformed entry that
# matched nothing would turn a typo into a permanently failing check — or,
# matched too loosely, into a permanently passing one.
for c in "${cidrs[@]}"; do
  [[ $c =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || {
    echo "::error::oidc.egressCidrs contains '$c', which is not an IPv4 CIDR in a.b.c.d/n form; refusing to judge the answer against a rule this check cannot evaluate" >&2
    exit 1
  }
done

echo "resolving $host (issuer $issuer) through public DNS"
if ! answer=$(dig +short A "$host" 2>&1); then
  echo "::error::dig +short A $host failed (resolver error, SERVFAIL or no reachable server). An unresolvable issuer drops the pod's discovery request just like a blocked one, so this is a failure, not a pass." >&2
  exit 1
fi

# dig +short prints the CNAME chain before the addresses; keep IPv4 answers only.
mapfile -t addrs < <(printf '%s\n' "$answer" | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || true)
if [ "${#addrs[@]}" -eq 0 ]; then
  echo "::error::dig +short A $host returned no IPv4 address (raw answer: '${answer}'). A name that resolves to nothing is the same outage as a name that resolves somewhere forbidden." >&2
  exit 1
fi

echo "resolved to ${#addrs[@]} IPv4 address(es): ${addrs[*]}"
echo "allowed CIDRs from $values_file: ${cidrs[*]}"

failed=0
for ip in "${addrs[@]}"; do
  inside=0
  for c in "${cidrs[@]}"; do
    if in_cidr "$ip" "$c"; then inside=1; break; fi
  done
  if [ "$inside" -eq 1 ]; then
    echo "  ok    $ip is inside the egress CIDRs"
  else
    failed=1
    echo "::error::$host resolves to $ip, which is outside every CIDR in $values_file (${cidrs[*]}) — if this is the address the pod sees, its OIDC discovery request is dropped by the wiki NetworkPolicy and no login completes. Update oidc.egressCidrs to the new edge address (and re-measure from inside the pod; this job only sees the public view)."
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "::error::the OIDC issuer does not resolve inside the egress CIDRs; see the per-address lines above"
  exit 1
fi

echo "every resolved address of $host is inside the egress CIDRs"
