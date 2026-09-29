# Runbook: mint a per-source LiteLLM key

Mint a named API key for the LiteLLM gateway, store it in sops, and hand it to a
client (pi, opencode, …). The key's name becomes the `api_key_alias` prometheus
label, so the LLM-fleet dashboard can break down requests/tokens per source.

**Ticket:** nix-config-mestruble-6lg.7

---

## What the key does

- Authenticates a client against the gateway (`Authorization: Bearer <key>`).
- Is stored in the gateway's Postgres key store (survives pod restarts).
- Is also encrypted into `homelab-secrets.yaml` so it survives a fresh PVC and can
  be re-handed to the client.
- Carries `api_key_alias=<name>` on every request metric it makes.

---

## Prerequisites

- The gateway is deployed with the Postgres key store:
  - **Prod** (`http://mjolnir:8000`) — only after the cutover (`usePostgresKeys: true`).
  - **Test pod** (`http://mjolnir:8001`) — while `testPod: true` (current state).
- `sops` on PATH.
- The master key is in sops (`.services.ai.litellm.master-key`). It gates `/key/*`.

Check the gateway is up:

```bash
curl -fsS http://mjolnir:8000/health/readiness   # prod
curl -fsS http://mjolnir:8001/health/readiness   # test pod
```

---

## Mint a key

```bash
just mint-key <name>
```

e.g. `just mint-key pi`.

It prints the key and stores it at `.services.ai.litellm.keys.<name>` in
`nix/services/homelab/homelab-secrets.yaml`. **Copy the key now** — it's only
printed once (the sops copy is the durable record).

To mint against the test pod instead of prod:

```bash
LITELLM_GATEWAY=http://mjolnir:8001 just mint-key pi
```

---

## Use the key

Point the client at the gateway's OpenAI-compatible endpoint with the key:

```
base_url:  http://mjolnir:8000/v1        # prod
api_key:   sk-...                        # the minted key
model:     gemma-4-26b-a4b               # or swift-qwen3.8-27b
```

Quick smoke test:

```bash
curl -fsS http://mjolnir:8000/v1/chat/completions \
  -H "Authorization: Bearer sk-..." \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma-4-26b-a4b","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
```

---

## Verify the alias is flowing to prometheus

After a request, the key's alias appears on the metrics:

```bash
curl -fsSL http://mjolnir:8000/metrics | grep -oE 'api_key_alias="[^"]*"' | sort -u
```

You should see `api_key_alias="<name>"`. (The label is emitted by default on the
request/token metrics — no extra config needed.)

---

## List / revoke keys

List keys (name + alias) from the Postgres key store:

```bash
ssh mjolnir 'sudo k3s kubectl exec -n default deploy/postgres -- \
  psql -U litellm -d litellm -c "SELECT key_name, key_alias FROM \"LiteLLM_VerificationToken\";"'
```

Revoke a key by alias (the gateway deletes it from the DB):

```bash
MASTER="$(sops decrypt nix/services/homelab/homelab-secrets.yaml | nix run nixpkgs#yq -- -r '.services.ai.litellm."master-key"')"
curl -fsS -X DELETE "http://mjolnir:8000/key/delete" \
  -H "Authorization: Bearer $MASTER" \
  -H "Content-Type: application/json" \
  -d '{"keys":["sk-..."]}'
```

Then remove the sops entry:

```bash
nix run nixpkgs#yq -- -i 'del(.services.ai.litellm.keys.<name>)' nix/services/homelab/homelab-secrets.yaml
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `no master key in ...` | `.services.ai.litellm.master-key` is missing from sops. |
| `401` on `/key/generate` | Master key wrong, or the gateway isn't the key-store build (prod is keyless until the cutover). Mint against `:8001` while `testPod: true`. |
| `Key with alias '<name>' already exists` | Aliases are unique. Revoke the old key first, or use a new name. |
| `mint failed` / connection refused | Gateway pod down. `ssh mjolnir 'sudo k3s kubectl get pods -n default -l app=litellm'`. |
| Alias not in `/metrics` | No request has been made with that key yet (the label is per-request). Make one, then re-check. |

---

## Notes

- The key store is Postgres on a static hostPath PV (`/var/lib/postgres-data`,
  uid 999). If the PV is wiped, re-mint the keys (the sops copies are the source
  of truth for re-handing them out).
- The master key is NOT a client key — it only manages `/key/*`. Clients always
  use their own minted key.
