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

Then commit the sops file — an uncommitted mint is lost on `git checkout`/
rebase, and `just deploy` refuses a dirty tree:

```bash
git add nix/services/homelab/homelab-secrets.yaml
git commit -m "mint litellm key <name>"
```

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

(Commit the sops change afterwards, as in *Mint a key*.)

---

## Secrets & age keys

Both sops files (`nix/services/homelab/homelab-secrets.yaml`,
`nix/users/sops-secrets.yaml`) are encrypted to the three age recipients in
`.sops.yaml`. A machine can decrypt only if it holds the matching private key.

| Machine | Private key location |
|---------|----------------------|
| Mac (mestruble) | `~/.config/sops/age/keys.txt` |
| roque | `~/.config/sops/age/keys.txt` |
| mjolnir | `/var/lib/sops-nix/key.txt` (sops-nix, see `nix/tools/sops.nix`) |

**Backup:** copy each private key to offline storage (e.g. encrypted password
manager or an offline disk). If a key is lost, that machine can no longer
decrypt — you can only drop its recipient from `.sops.yaml` and re-encrypt
(see below), never recover the key.

**Rotation / re-encryption** (e.g. a key is lost, or a machine is rebuilt):

1. Install the new private key on the machine (mjolnir: replace
   `/var/lib/sops-nix/key.txt`).
2. Update the recipient in `.sops.yaml`.
3. Re-encrypt the sops files to the new recipient set:
   ```bash
   sops updatekeys nix/services/homelab/homelab-secrets.yaml
   sops updatekeys nix/users/sops-secrets.yaml
   ```
4. `git commit` + `just deploy mjolnir`.

**Re-apply:** `just deploy mjolnir` (`nix run .#deploy-rs -- .#mjolnir`) is
what ships a changed sops value — sops-nix decrypts at activation and
materialises `/run/secrets`. Until you deploy, the cluster keeps the old
values.

> **Acute for this branch:** the mjolnir recipient is rotated
> (`age1m8d99…` → `age1ng45h…`). If the new private key is not installed at
> `/var/lib/sops-nix/key.txt` before deploy, the cluster cannot decrypt
> `/run/secrets` and every secret-fed component breaks.

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
  uid 999). After a PV wipe the minted keys are dead — the fresh DB doesn't
  know them. Re-mint each alias (`just mint-key <name>`), which overwrites the
  sops entry, and re-hand the new keys to the clients. The sops copies are the
  re-handing record, not a re-authentication mechanism.
- Trust assumption: the gateway is reached over cleartext HTTP on a trusted
  single-subnet LAN — the master key and minted keys transit in cleartext
  `Authorization` headers.
- The master key is NOT a client key — it only manages `/key/*`. Clients always
  use their own minted key.
