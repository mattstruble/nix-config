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
umask 077
T="$(mktemp -d)"
trap 'rm -rf "$T"; rm -f "$F.new"' EXIT

# 1. master key from sops (gates /key/*).
sops decrypt "$F" > "$T/plain.yaml"
MASTER="$("${YQ[@]}" -r '.services.ai.litellm."master-key"' "$T/plain.yaml")"
[[ -n "$MASTER" && "$MASTER" != "null" ]] || { echo "no master key in $F" >&2; exit 1; }

# Keep the master key out of process argv: curl reads it from a 0600 config.
printf 'header = "Authorization: Bearer %s"\n' "$MASTER" > "$T/curl.conf"

# 2. idempotency: if the alias already exists, print the stored key and stop.
CODE="$(curl -sS --max-time 30 -o "$T/info.json" -w '%{http_code}' \
  -K "$T/curl.conf" "$GATEWAY/key/info?key=$NAME")"
if [[ "$CODE" == "200" ]]; then
  STORED="$("${YQ[@]}" -r ".services.ai.litellm.keys.\"$NAME\" // empty" "$T/plain.yaml")"
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

# 4. store in sops: decrypt -> add -> re-encrypt at the original path so the
#    creation rules apply. Encrypt to a temp file, then mv over the original so
#    the file is never left half-written (or plaintext) in the tree.
KEY="$KEY" "${YQ[@]}" -yi ".services.ai.litellm.keys.\"$NAME\" = \$ENV.KEY" "$T/plain.yaml"
sops encrypt "$T/plain.yaml" > "$F.new" && mv "$F.new" "$F"

echo "Minted key for '$NAME':"
echo "$KEY"
echo "Stored: $F  (services.ai.litellm.keys.$NAME)"
echo "Point the client at $GATEWAY/v1 with this key."
