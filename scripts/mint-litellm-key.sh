#!/usr/bin/env bash
# Mint a new named LiteLLM API key, store it in sops, print it.
#
#   just mint-key <name>
#
# The key's alias == <name>, which becomes the `api_key_alias` prometheus label
# (per-source breakdown on the LLM fleet dashboard). The key is persisted
# in the gateway's Postgres key store AND encrypted into homelab-secrets.yaml so
# it survives a fresh PVC and can be handed to the client.
#
# Idempotent: if a key with this alias already exists in the gateway, the
# stored sops value is printed and the script exits 0 without minting a
# duplicate.
set -euo pipefail

NAME="${1:?usage: just mint-key <name>}"
F="nix/services/homelab/homelab-secrets.yaml"
GATEWAY="${LITELLM_GATEWAY:-http://mjolnir:8000}"
YQ=(nix run nixpkgs#yq --)

# NAME becomes a JSON field, a yq path, and a prometheus label: restrict it to
# a safe charset before it is interpolated anywhere.
[[ "$NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || {
  echo "invalid key name '$NAME': must match ^[a-zA-Z0-9][a-zA-Z0-9_-]*$" >&2
  exit 1
}

command -v sops >/dev/null || { echo "sops not on PATH" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 1; }

# All plaintext (decrypted secrets, API responses, curl config) lives in a
# private temp dir removed on exit; nothing is written to a fixed path.
# The plaintext is mirrored at the repo-relative path under $T (and .sops.yaml
# is copied in) so that `sops encrypt` finds the same creation rule the file
# was created with — sops matches path_regex against the file path, and a
# bare temp path would match no rule and re-encrypt to the wrong keys.
umask 077
T="$(mktemp -d)"
mkdir -p "$T/nix/services/homelab"
cp .sops.yaml "$T/.sops.yaml"
trap 'rm -rf "$T"; rm -f "$F.new"' EXIT

# 1. master key from sops (gates /key/*).
PLAIN="$T/nix/services/homelab/$(basename "$F")"
sops decrypt "$F" > "$PLAIN"
MASTER="$("${YQ[@]}" -r '.services.ai.litellm."master-key"' "$PLAIN")"
[[ -n "$MASTER" && "$MASTER" != "null" ]] || { echo "no master key in $F" >&2; exit 1; }

# Keep the master key out of process argv: curl reads it from a 0600 config.
printf 'header = "Authorization: Bearer %s"\n' "$MASTER" > "$T/curl.conf"

# 2. idempotency: if the alias already exists, print the stored key and stop.
# /key/list returns every key with its key_alias. (NOT /key/info — that takes
# the key TOKEN, not the alias, so ?key=$NAME would never match.)
CODE="$(curl -sS --max-time 30 -o "$T/list.json" -w '%{http_code}' \
  -K "$T/curl.conf" "$GATEWAY/key/list")"
if [[ "$CODE" == "200" ]]; then
  EXISTS="$(jq -r --arg n "$NAME" '[.keys[]? | select(.key_alias == $n)] | length' "$T/list.json" 2>/dev/null || echo 0)"
  if [[ "$EXISTS" -gt 0 ]]; then
    STORED="$("${YQ[@]}" -r ".services.ai.litellm.keys.\"$NAME\" // empty" "$PLAIN")"
    if [[ -n "$STORED" ]]; then
      echo "Key '$NAME' already exists; stored key:"
      echo "$STORED"
      echo "Stored: $F  (services.ai.litellm.keys.$NAME)"
      exit 0
    fi
    echo "key '$NAME' already exists in the gateway but is missing from $F" >&2
    echo "revoke it first (docs/runbook-mint-litellm-key.md), then re-run" >&2
    exit 1
  fi
fi

# 3. mint via the gateway API (master key via config file, not argv).
CODE="$(curl -sS --max-time 30 -X POST -o "$T/resp.json" -w '%{http_code}' \
  -K "$T/curl.conf" -H "Content-Type: application/json" \
  -d "{\"key_alias\":\"$NAME\",\"key_name\":\"$NAME\"}" "$GATEWAY/key/generate")"
KEY=""
if [[ "$CODE" =~ ^2 ]]; then
  KEY="$(jq -r '.key // .token // empty' "$T/resp.json")"
fi
if [[ -z "$KEY" ]]; then
  # Redacted: only the gateway's error field, never the response body.
  MSG="$(jq -r '.message // .error // "unexpected response"' "$T/resp.json" 2>/dev/null || echo "unexpected response (HTTP $CODE)")"
  echo "mint failed from $GATEWAY (HTTP $CODE): $MSG" >&2
  exit 1
fi

# 4. store in sops: add the key to the mirrored plaintext, then re-encrypt.
#    Because the plaintext sits at the repo-relative path under $T with
#    .sops.yaml alongside, sops applies the same creation rule (same age
#    recipients) the file was created with. Encrypt to a temp file, then mv
#    over the original so the file is never left half-written (or plaintext)
#    in the tree.
KEY="$KEY" "${YQ[@]}" -yi ".services.ai.litellm.keys.\"$NAME\" = \$ENV.KEY" "$PLAIN"
sops encrypt "$PLAIN" > "$F.new" && mv "$F.new" "$F"

echo "Minted key for '$NAME':"
echo "$KEY"
echo "Stored: $F  (services.ai.litellm.keys.$NAME)"
echo "Point the client at $GATEWAY/v1 with this key."
