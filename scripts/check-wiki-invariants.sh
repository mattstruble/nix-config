#!/usr/bin/env bash
#
# Fail when a wiki value that lives in two files says two different things.
#
#   ./scripts/check-wiki-invariants.sh
#
# Neither pair below has a single source of truth: no import, template or
# validation crosses the file boundary, so today the agreement is carried by the
# comment on each side that names the other, and by the memory of whoever set the
# number up.
#
# 1. bookstack.uid / database.uid (k8s/apps/wiki/values.yaml) and the owner and
#    group of the matching systemd.tmpfiles rule (nix/services/k3s.nix). The
#    directories under the PV's host path are pre-owned by the numeric id at
#    activation because the cluster's non-root stance forbids a root chown
#    initContainer; change one side alone and the pod runs as an id that cannot
#    write the directory it mounts. MariaDB is the worse case: the image chowns
#    and initialises only an empty datadir, so the datadir keeps the owner it was
#    created with and reverting the values file does not undo it — the directory
#    has to be chowned back on mjolnir by hand.
# 2. persistence.size (values.yaml) and spec.capacity.storage
#    (k8s/manifests/wiki-local-pv.yaml). The PV is static and pre-bound by
#    claimRef, so a claim asking for more than the PV offers is simply never
#    bound: the PVC and the pod both sit Pending, and the events say only that no
#    persistent volume found.
#
# What a green run does NOT claim:
#   - the Secret name pair. `secretName` in values.yaml and the name hardcoded in
#     the activation script are the same kind of invariant and are deliberately
#     not checked here; see the workflow header for why, and for when it returns.
#   - anything about both sides of a pair moving together. A commit that changes
#     a pair on both sides is a legitimate edit and passes: this compares two
#     strings and knows nothing about what either number means.
#   - the mode column of the tmpfiles rules, the storage class name, the
#     claimRef namespace, or any other cross-file name in the wiki stack.
set -euo pipefail

# `CDPATH= cd` is a prefix assignment, not an empty one: CDPATH must not redirect this.
# shellcheck disable=SC1007
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

values_file=k8s/apps/wiki/values.yaml
pv_file=k8s/manifests/wiki-local-pv.yaml
nix_file=nix/services/k3s.nix

for f in "$values_file" "$pv_file" "$nix_file"; do
  [ -f "$f" ] || {
    echo "::error::$f is missing, so the pair it belongs to cannot be compared at all" >&2
    exit 1
  }
done

workflow_file=.github/workflows/wiki-invariants.yml
./scripts/assert-paths-filter.sh "$workflow_file" \
  "$values_file" "$pv_file" "$nix_file" "$workflow_file" "${0#./}"

failed=0

# Every extraction demands exactly one match. A silent first-match-wins reading
# is the false negative this file exists to avoid: with a duplicated key the
# checker would compare one occurrence and go green while Helm's YAML parser kept
# the last one.
one_match() { # $1 = value(s), one per line; $2 = what was looked for; $3 = file
  local n
  n=$(printf '%s\n' "$1" | grep -c . || true)
  [ "$n" -eq 1 ] || {
    echo "::error::found $n occurrence(s) of $2 in $3: a value this check cannot read unambiguously is as fatal as a disagreement" >&2
    exit 1
  }
  printf '%s' "$1"
}

# A top-level key opens a block and any deeper key of that name belongs to it, so
# `bookstack.uid` cannot be satisfied by the `uid` under `database:`.
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

# The tmpfiles rules are NixOS config, not chart config: they run at activation on
# the host, before kubelet mounts anything, which is exactly why nothing connects
# them to the values file.
tmpfiles_get() { # $1 = directory under /var/lib/wiki, $2 = 4 (owner) or 5 (group)
  grep -E "^[[:space:]]*\"d /var/lib/wiki/$1 [0-9]+ [0-9]+ [0-9]+ -\"" "$nix_file" |
    awk -v f="$2" '{ print $f }' || true
}

pv_get() {
  # `storage:` and not `storageClassName:`: the colon position separates them.
  grep -E "^[[:space:]]*storage:[[:space:]]*[^[:space:]]" "$pv_file" |
    sed -E 's/^[[:space:]]*storage:[[:space:]]*//; s/[[:space:]]*(#.*)?$//; s/^"|"$//g' || true
}

compare() { # $1 = what, $2 = left value, $3 = left place, $4 = right value, $5 = right place, $6 = cost of drift
  if [ "$2" = "$4" ]; then
    printf '  ok    %-40s %-6s %s == %s\n' "$1" "$2" "$3" "$5"
    return
  fi
  failed=1
  echo "::error::$1 disagrees: $3 is '$2' but $5 is '$4'. $6 Change both files in one commit; either one alone is the failure this check exists for."
}

echo "wiki cross-file invariants"

bookstack_uid=$(one_match "$(values_get bookstack.uid)" "bookstack.uid" "$values_file")
bookstack_gid=$(one_match "$(values_get bookstack.gid)" "bookstack.gid" "$values_file")
database_uid=$(one_match "$(values_get database.uid)" "database.uid" "$values_file")
database_gid=$(one_match "$(values_get database.gid)" "database.gid" "$values_file")
claim_size=$(one_match "$(values_get persistence.size)" "persistence.size" "$values_file")

bookstack_dir_uid=$(one_match "$(tmpfiles_get bookstack 4)" "owner of the /var/lib/wiki/bookstack tmpfiles rule" "$nix_file")
bookstack_dir_gid=$(one_match "$(tmpfiles_get bookstack 5)" "group of the /var/lib/wiki/bookstack tmpfiles rule" "$nix_file")
mysql_dir_uid=$(one_match "$(tmpfiles_get mysql 4)" "owner of the /var/lib/wiki/mysql tmpfiles rule" "$nix_file")
mysql_dir_gid=$(one_match "$(tmpfiles_get mysql 5)" "group of the /var/lib/wiki/mysql tmpfiles rule" "$nix_file")
pv_size=$(one_match "$(pv_get)" "spec.capacity.storage" "$pv_file")

compare "bookstack.uid vs tmpfiles owner" \
  "$bookstack_uid" "$values_file" "$bookstack_dir_uid" "$nix_file" \
  "BookStack runs as the id from values after s6 init and the host directory is owned by the id in the rule, so the app cannot write /config."
compare "bookstack.gid vs tmpfiles group" \
  "$bookstack_gid" "$values_file" "$bookstack_dir_gid" "$nix_file" \
  "same directory, same reason."
compare "database.uid vs tmpfiles owner" \
  "$database_uid" "$values_file" "$mysql_dir_uid" "$nix_file" \
  "MariaDB chowns and initialises only an empty datadir, so a populated /var/lib/wiki/mysql keeps its old owner and a revert of either file alone does not undo it."
compare "database.gid vs tmpfiles group" \
  "$database_gid" "$values_file" "$mysql_dir_gid" "$nix_file" \
  "same directory, same reason."
compare "persistence.size vs PV capacity" \
  "$claim_size" "$values_file" "$pv_size" "$pv_file" \
  "the static PV is pre-bound by claimRef, so a claim larger than it is never bound and the wiki pods stay Pending."

if [ "$failed" -ne 0 ]; then
  echo "::error::a wiki value pair above disagrees; the two sides are read by different software and nothing else connects them"
  exit 1
fi

echo "all wiki cross-file values agree"
