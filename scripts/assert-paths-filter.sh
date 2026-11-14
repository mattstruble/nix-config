#!/usr/bin/env bash
#
# Assert that a workflow's pull_request `paths:` filter covers every file the
# caller reads.
#
#   ./scripts/assert-paths-filter.sh <workflow.yml> <file> [<file> ...]
#
# GitHub skips a workflow entirely when no changed file matches its filter, so a
# file added to a check and forgotten in the filter is a check that passes by
# never running. That is the one failure mode a cross-file check cannot survive:
# the PR that breaks the invariant touches one of the files by construction.
#
# A filter entry ending in /** covers every path under that prefix. Anything else
# has to match the file exactly.
#
# Exits 0 when every file is covered, 1 when any is not, 2 on a usage error.
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <workflow.yml> <file> [<file> ...]" >&2
  exit 2
fi

workflow=$1
shift

if [ ! -f "$workflow" ]; then
  echo "::error::$workflow is missing, so its paths: filter cannot be read" >&2
  exit 1
fi

# The filter is the list under the first `paths:` key, up to the first line that
# is not a list item. Quoting is stripped so the comparison is against the path.
filter=$(awk '
  !seen && /^[[:space:]]*paths:/ { seen = 1; next }
  seen {
    if ($0 ~ /^[[:space:]]*- /) {
      line = $0
      sub(/^[[:space:]]*- /, "", line)
      gsub(/^"|"$/, "", line)
      print line
      next
    }
    exit
  }
' "$workflow")

if [ -z "$filter" ]; then
  echo "::error::$workflow declares no pull_request paths: filter, so this check would run for no PR at all" >&2
  exit 1
fi

missing=0
for f in "$@"; do
  covered=0
  while IFS= read -r entry; do
    case "$entry" in
      */"**")
        prefix=${entry%"**"}
        if [ "${f#"$prefix"}" != "$f" ]; then
          covered=1
          break
        fi
        ;;
      *)
        if [ "$entry" = "$f" ]; then
          covered=1
          break
        fi
        ;;
    esac
  done <<<"$filter"

  if [ "$covered" = 0 ]; then
    echo "::error::$f is read by this check but is not in $workflow's paths: filter — a PR touching only this file never runs the check, so the check passes by never running" >&2
    missing=1
  fi
done

if [ "$missing" = 1 ]; then
  echo "::error::add every file named above to $workflow's paths: filter, or stop reading it here" >&2
  exit 1
fi
