#!/usr/bin/env bash
# Mint a new named LiteLLM API key, store it in sops, print it.
#
#   just mint-key <name>
#
# The key's alias == <name>, which becomes the `api_key_alias` prometheus label
# (per-source breakdown on the LLM fleet dashboard). The key is persisted
# in the gateway's Postgres key store AND encrypted into homelab-secrets.yaml so
# it survives a fresh PVC and can be handed to the client.
set -euo pipefail

NAME="${1:?usage: just mint-key <name>}"
F="nix/services/homelab/homelab-secrets.yaml"
GATEWAY="${LITELLM_GATEWAY:-http://mjolnir:8000}"
YQ=(nix run nixpkgs#yq)

command -v sops >/dev/null || { echo "sops not on PATH" >&2; exit 1; }

# 1. master key from sops (gates /key/*).
MASTER="$(sops decrypt "$F" | "${YQ[@]}" -r '.services.ai.litellm."master-key"')"
[[ -n "$MASTER" && "$MASTER" != "null" ]] || { echo "no master key in $F" >&2; exit 1; }

# 2. mint via the gateway API.
RESP="$(curl -fsS -X POST "$GATEWAY/key/generate" \
  -H "Authorization: Bearer $MASTER" \
  -H "Content-Type: application/json" \
  -d "{\"key_alias\":\"$NAME\",\"key_name\":\"$NAME\"}")"
KEY="$(printf '%s' "$RESP" | jq -r '.key // .token // empty')"
if [[ -z "$KEY" ]]; then
  echo "mint failed from $GATEWAY:" >&2
  printf '%s\n' "$RESP" >&2
  exit 1
fi

# 3. store in sops (decrypt -> add -> re-encrypt at the original path so the
#    creation rules apply).
sops decrypt "$F" > /tmp/hl-plain.yaml
"${YQ[@]}" -yi ".services.ai.litellm.keys.\"$NAME\" = \"$KEY\"" /tmp/hl-plain.yaml
cp /tmp/hl-plain.yaml "$F"
sops encrypt --in-place "$F"

echo "Minted key for '$NAME':"
echo "$KEY"
echo "Stored: $F  (services.ai.litellm.keys.$NAME)"
echo "Point the client at $GATEWAY/v1 with this key."
