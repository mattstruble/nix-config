#!/usr/bin/env bash
# Regenerate corpus.txt (harness --corpus default). Run on mjolnir, where both trees exist.
# Order only shifts where the needle lands: harness.py inserts it at char 60000.
set -euo pipefail
CONF="${1:-/etc/nixos}"
SRC="${2:-/var/lib/llama-builds/llama.cpp}"
{ find "$CONF" -name '*.nix' -readable -print0 2>/dev/null | xargs -0 cat
  for d in common examples tests ggml/src; do
    find "$SRC/$d" \( -name '*.cpp' -o -name '*.h' \) -readable -print0 2>/dev/null | xargs -0 cat
  done
} > "$(dirname "$0")/corpus.txt"
wc -c "$(dirname "$0")/corpus.txt"
