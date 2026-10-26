#!/usr/bin/env bash
#
# Check - and optionally repair - the sha256 pins of the Helm chart tarballs
# fetched with fetchurl in nix/services/k3s.nix.
#
#   ./scripts/chart-hashes.sh                        # check every pin
#   ./scripts/chart-hashes.sh --fix --against HEAD   # repair only pins whose URL
#                                                    # this branch changed
#
# Why: Renovate's nix manager only understands flake inputs, so a chart bump
# arrives as a new URL carrying the OLD hash, and the PR cannot go green until
# someone recomputes it. `pkgs.fetchurl`'s sha256 is the plain hash of the
# downloaded file (verified against all three current pins), so recomputing it
# needs curl and sha256sum rather than a Nix evaluation - which matters because
# nothing in CI reliably forces these derivations anyway.
#
# --fix only rewrites pins whose URL actually moved. A pin whose URL did not
# move but whose hash disagrees is a re-pushed release asset, and adopting the
# new bytes silently is exactly what the pin exists to prevent; there, a red
# build is the correct outcome, so a scheduled run should use --check.
set -euo pipefail

file=nix/services/k3s.nix
mode=check
against=

while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode=check; shift ;;
    --fix) mode=fix; shift ;;
    --against) against=${2:?--against needs a revision}; shift 2 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

[ -f "$file" ] || { echo "no such file: $file" >&2; exit 2; }

# Parse, don't validate: emit one TSV row per pin - url line, url, sha line,
# hash - so every caller works on a structure that cannot be malformed. A pin is
# a release-asset URL whose immediately following sha256 line is 64 hex.
pins() {
  awk '
    /url = "https:\/\/github\.com\/[^"]+\/releases\/download\/[^"]+";/ {
      url = $0; gsub(/.*url = "/, "", url); gsub(/".*/, "", url); uline = NR; next
    }
    {
      if (uline && $0 ~ /sha256 = "[a-f0-9]{64}";/) {
        sha = $0; gsub(/.*sha256 = "/, "", sha); gsub(/".*/, "", sha)
        printf "%d\t%s\t%d\t%s\n", uline, url, NR, sha
        uline = 0
      } else { uline = 0 }
    }
  ' "$file"
}

# Download an asset and return its sha256, refusing anything that is not the
# gzip tarball a Helm chart is. A 404 page hashes just fine, so the HTTP status
# alone is not enough.
asset_hash() {
  local url=$1 out=$2
  curl -sSL --fail --connect-timeout 10 --max-time 300 -o "$out" "$url" || return 1
  [ "$(head -c2 "$out" | od -An -tx1 | tr -d ' \n')" = "1f8b" ] || return 1
  sha256sum "$out" | cut -d' ' -f1
}

# Rewrite one line's hash without touching anything else on it - the trailing
# `# pragma: allowlist secret` has to survive.
rewrite_hash() {
  local line=$1 old=$2 new=$3 out
  out=$(mktemp)
  awk -v n="$line" -v old="$old" -v new="$new" '
    NR == n { sub(old, new) }
    { print }
  ' "$file" > "$out"
  cat "$out" > "$file"
  rm -f "$out"
}

changed_urls=
if [ -n "$against" ]; then
  changed_urls=$(git diff --no-color "$against" -- "$file" | grep '^+' || true)
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
checked=0
repaired=0
failed=0

while IFS=$'\t' read -r uline url shaLine want; do
  [ -n "${url:-}" ] || continue
  checked=$((checked + 1))
  name=${url##*/download/}

  if [ "$mode" = fix ] && [ -n "$against" ] && ! printf '%s' "$changed_urls" | grep -qF "$url"; then
    echo "skip   $name (url unchanged vs $against)"
    continue
  fi

  if ! got=$(asset_hash "$url" "$tmp"); then
    echo "FAIL   $name - download failed or is not a gzip archive; refusing to guess a hash" >&2
    failed=1
    continue
  fi

  if [ "$got" = "$want" ]; then
    echo "ok     $name  ${got:0:12}…"
  elif [ "$mode" = fix ]; then
    rewrite_hash "$shaLine" "$want" "$got"
    echo "fixed  $name  ${want:0:12}… -> ${got:0:12}…"
    repaired=$((repaired + 1))
  else
    echo "MISMATCH  $name  pinned ${want:0:12}… but the asset hashes to ${got:0:12}…" >&2
    failed=1
  fi
done <<< "$(pins)"

echo "$checked pin(s), $repaired repaired"
exit $failed
