# Security/ops audit: secrets, key-mint script, runbook

**Ticket:** mestruble-3x7.8 — "[review] Security/ops audit: secrets, key-mint script, runbook"
**Repo:** /Users/mestruble/Software/nix-config (branch `feat/observability`, base `main`)
**Date:** 2026-02-14
**Method:** file-by-file review against `docs/review/feat-observability/research.md` §6 (secrets) + k8s-operations/logging skill baselines; `git diff main...HEAD` and `k8s/` tree grepped for plaintext key-like strings; secret-to-k8s wiring traced through `nix/services/k3s.nix`; exposure surface enumerated from chart templates + monitoring values.

**Scope (every file reviewed):**
- `nix/services/homelab/homelab-secrets.yaml` — the sops-encrypted secrets file (task named `k8s/apps/ai/secrets.sops.yaml`; no such file exists on this branch — this is the actual sops file)
- `scripts/mint-litellm-key.sh`
- `docs/runbook-mint-litellm-key.md`
- `.sops.yaml`
- `.pre-commit-config.yaml` (detect-secrets / sops-encryption hooks)
- Cross-referenced (not separately scored): `nix/services/k3s.nix` (sops→k8s wiring), `k8s/apps/ai/templates/*` (exposure surface), `k8s/apps/monitoring/values/*` (exposure surface)

---

## Findings

### P0 — none

No plaintext secrets found anywhere in the branch. `git diff main...HEAD` + full `k8s/` tree greps for `sk-…`, Bearer tokens, and password-like assignments return only: the sops-encrypted `ENC[AES256_GCM,…]` values, the `__TELEGRAM_*` placeholders (substituted from `/run/secrets` at activation), `# pragma: allowlist secret` comments on key *names* (not values), and the `sk-…` placeholder in the runbook's example commands. The sops file is the single source of truth for all sensitive values (research §6.6 satisfied).

### P1

**P1-1 — `k8s/apps/ai/templates/gateway-configmap.yaml:25` — gateway `/metrics` is unauthenticated and LAN-reachable via hostPort 8000**
`require_auth_for_metrics_endpoint: false` disables auth on LiteLLM's `/metrics` (research §3.7: the endpoint normally requires `Authorization: Bearer <key>`). The gateway binds `hostPort: 8000`, which is DNAT'd straight to the pod and bypasses the host firewall (per the comment in `nix/services/k3s.nix`), so `http://mjolnir:8000/metrics` serves spend/token/latency metrics to **anyone on the LAN with no credential**. The in-cluster ServiceMonitor scrape does not need the hostPort (it uses the ClusterIP Service), so the only reason the endpoint is exposed is the client-facing hostPort.
**Fix:** set `require_auth_for_metrics_endpoint: true` and give the `ai-fleet` ServiceMonitor a real gateway key: mint a dedicated metrics key (`just mint-key metrics`), add it to the `litellm-keys` Secret, and point the monitor's `bearerTokenFile` at it (note: the current `llm-api-key` token `foo` is a llama.cpp pod key, **not** a valid gateway key — enabling auth with it would 401 the gateway scrape; the model pods keep using `foo`).

**P1-2 — `scripts/mint-litellm-key.sh:24-27` — not idempotent: no check-for-existing before create**
Research §6.4 requires "check-for-existing before create (safe re-run)". Re-running `just mint-key pi` POSTs to `/key/generate` unconditionally and fails with `Key with alias 'pi' already exists` (the runbook's own troubleshooting table documents this). A re-run after a partial failure (e.g. mint succeeded but the sops write failed) is exactly the case where idempotency matters.
**Fix:** before creating, `GET $GATEWAY/key/info` (master key) or list keys and check for `key_alias == $NAME`; if it exists, print the key from the sops copy (`.services.ai.litellm.keys.$NAME`) and exit 0; if the sops copy is missing, fail with a clear "revoke first" message.

**P1-3 — `scripts/mint-litellm-key.sh:37-40` — all decrypted secrets written to a fixed, world-readable temp file that is never deleted**
`sops decrypt "$F" > /tmp/hl-plain.yaml` dumps the **entire** decrypted secrets file (grafana password, telegram token, master key, postgres password, all minted keys) to a predictable path with default umask (world-readable on most setups), and the file is left behind after the script exits (no `rm`, no `trap`). Any local user/session can read every homelab secret from `/tmp` afterwards. The activation script in `k3s.nix` does this correctly (`mktemp -d` + `trap 'rm -rf' EXIT`) — the mint script should match.
**Fix:**
```bash
umask 077
T="$(mktemp)"
trap 'rm -f "$T"' EXIT
sops decrypt "$F" > "$T"
"${YQ[@]}" -yi ".services.ai.litellm.keys.\"$NAME\" = \"$KEY\"" "$T"
cp "$T" "$F"
```

**P1-4 — `docs/runbook-mint-litellm-key.md` — missing the three runbook sections research §6.5 requires**
(a) **age key location + backup: absent.** No section says where the age private keys live (`~/.config/sops/age/keys.txt` on MacStruble/roque/mjolnir) or how they're backed up. This is acute on this branch: `.sops.yaml` **rotates the mjolnir recipient** (`age1m8d99…` → `age1ng45h…`) and the sops file was re-encrypted to the new key — if the new private key isn't installed on mjolnir before deploy, the cluster cannot decrypt `/run/secrets` and every secret-fed component (gateway, postgres, grafana, alertmanager) breaks with no recovery path documented. (b) **sops secret rotation/re-encryption: absent** (no `sops updatekeys` / change-a-value-and-re-encrypt procedure). (c) **exact re-apply commands after a secret change: absent** (the runbook never says `just deploy mjolnir` / `nixos-rebuild switch --flake .#mjolnir` is what ships a changed sops value to the cluster).
**Fix:** add a "Secrets & age keys" section: key locations per machine + backup method (e.g. encrypted password manager), `sops updatekeys nix/services/homelab/homelab-secrets.yaml` after a key rotation, and "after editing the sops file: `git commit` + `just deploy mjolnir` (activation script re-applies the `litellm-keys`/`monitoring-secrets` Secrets idempotently)".

### P2

**P2-1 — `.pre-commit-config.yaml:33` — detect-secrets exclusion is broader than the sops file**
`exclude: (.*lock)|(secrets.yaml)|…` — `secrets.yaml` is an *unanchored substring*, so it matches **any** file ending in `secrets.yaml` anywhere in the repo (e.g. a future `k8s/apps/ai/secrets.yaml` with plaintext would be silently skipped). It is not scoped to exactly the sops files.
**Fix:** `exclude: (.*lock)|(nix/services/homelab/homelab-secrets\.yaml)|(nix/users/sops-secrets\.yaml)`. (The newly added `k8s/apps/monitoring/values/kube-prometheus-stack.yaml` exclusion is verified harmless — the file contains only placeholders and key names, no values — but is unnecessary since detect-secrets would pass it as-is; keep or drop, your call.)

**P2-2 — `scripts/mint-litellm-key.sh:26,38` — secrets passed as process argv (visible in `ps`)**
`curl -H "Authorization: Bearer $MASTER"` puts the master key in curl's argv; `yq -yi "… = \"$KEY\""` puts the freshly minted key in yq's argv. Both are visible to any local user via `ps` for the duration of the call.
**Fix:** for curl, write a 0600 config file (`header = "Authorization: Bearer …"`) and use `curl -K "$cfg"` (with `trap` cleanup); for yq, pass the value via env (`KEY="$KEY" yq -i '.x = env(KEY)'`) or read it from the temp file.

**P2-3 — `scripts/mint-litellm-key.sh:31-34` — failure path prints the full response body (which contains the new key) to stderr**
If the gateway returns 200 with an unexpected shape (no `.key`/`.token`), the whole `RESP` — including the minted key — is dumped to stderr (and thus to shell history/CI logs).
**Fix:** print only the error field: `printf '%s\n' "$(printf '%s' "$RESP" | jq -c '{error: (.message // .error // "unexpected response")}' | sed 's/"key":"[^"]*"/"key":"<redacted>"/')" >&2`.

**P2-4 — `scripts/mint-litellm-key.sh:12,27` — `NAME` is unvalidated and interpolated into the JSON body**
`NAME` flows into `{"key_alias":"$NAME",…}` unescaped (a name containing `"` breaks/injects the JSON) and becomes a Prometheus label (`api_key_alias`).
**Fix:** `[[ "$NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || { echo "invalid key name" >&2; exit 1; }`.

**P2-5 — `scripts/mint-litellm-key.sh:14` + runbook — master key and minted keys transit cleartext over LAN HTTP**
`GATEWAY` defaults to `http://mjolnir:8000`; every mint/revoke sends the master key in a cleartext `Authorization` header. Acceptable on a trusted single-subnet homelab, but it's the weakest link in an otherwise sops-encrypted chain.
**Fix:** document the trust assumption in the runbook (one line), or terminate TLS at a LAN proxy (traefik already runs) and point `LITELLM_GATEWAY` at it.

**P2-6 — `nix/services/k3s.nix` (firewall) — node-exporter 9100 and kubelet 10250 opened to *all* sources**
The branch widens `allowedTCPPorts` from `[6443]` to `[6443 9100 10250]`. The comment says the intent is pod-CIDR→host reachability for Prometheus scrapes, but nixos `allowedTCPPorts` has no source restriction — the whole LAN can hit unauthenticated node-exporter (9100) and the kubelet API (10250; token-gated, but the surface is live).
**Fix:** add an nftables rule that accepts 9100/10250 only from the pod CIDR (e.g. `networking.nftables.ruleset` with `ip saddr 10.42.0.0/16`), keeping the INPUT chain closed to the rest of the LAN.

**P2-7 — `nix/services/k3s.nix` (activation) — kubelet-monitoring ServiceAccount token minted for 10 years**
`kubectl create token … --duration=87600h` is a long-lived bearer token stored in a Secret; a cluster compromise yields a 10-year-valid kubelet credential. The comment acknowledges the trade-off (no re-minting per deploy).
**Fix (optional):** accept and document, or move to a projected token with a shorter TTL + a cron/activation re-mint.

**P2-8 — `k8s/apps/monitoring/values/dcgm-exporter.yaml:19-25` — DCGM exporter pod runs as root with `SYS_ADMIN`**
Documented as required for CDI driver access, and the pod is in-cluster-only (not LAN-reachable), so this is an exposure *depth* gap, not a reachability one: a compromised DCGM pod is root on the node.
**Fix:** isolate it (dedicated namespace with an explicit PSS `baseline` label + networkPolicy) so the privileged exception is contained; cross-ref the chart/monitoring reviews for the rest of the DCGM findings.

**P2-9 — `k8s/apps/monitoring/values/kube-prometheus-stack.yaml:143-147` — Grafana ingress is HTTP-only**
`grafana.mjolnir` via traefik with no certificate configured — the sops-managed admin password crosses the LAN in cleartext.
**Fix:** add a self-signed (or internal CA) cert to the ingress (`tls:` block) — traefik is already the ingress class.

**P2-10 — `docs/runbook-mint-litellm-key.md` (Notes) — "re-mint" guidance is misleading**
"If the PV is wiped, re-mint the keys (the sops copies are the source of truth for re-handing them out)" conflates two things: the sops copy is a record for **re-handing keys to clients**, not a re-authentication mechanism — after a PV wipe the old keys are invalid in the fresh DB, so the sops entries must be **replaced** with newly minted keys, and every client re-pointed.
**Fix:** reword: "After a PV wipe the minted keys are dead. Re-mint each alias (`just mint-key <name>`), which overwrites the sops entry, and re-hand the new keys to clients."

**P2-11 — `scripts/mint-litellm-key.sh:39-40` — plaintext window in the working tree**
`cp /tmp/hl-plain.yaml "$F"` leaves the sops file **plaintext on disk** between the `cp` and `sops encrypt --in-place`; if the encrypt step fails (sops version drift, disk full), a plaintext secrets file sits in the working tree — one accidental `git add` away from committing every secret.
**Fix:** `sops encrypt "$T" > "$F.new" && mv "$F.new" "$F"` (atomic replace, no plaintext ever at `$F`).

**P2-12 — `docs/runbook-mint-litellm-key.md` (Mint a key) — no commit step**
The durable record is the sops file, but the runbook never says to `git commit` it after minting; an uncommitted mint is lost on `git checkout`/rebase.
**Fix:** add "then `git commit nix/services/homelab/homelab-secrets.yaml`" to the mint section.

**P2-13 — `scripts/mint-litellm-key.sh` (misc) — missing `jq` check, no curl timeout**
`command -v sops` is checked but `jq` (used at line 30) is not; `curl` has no `--max-time`, so a wedged gateway hangs the script forever.
**Fix:** `command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 1; }` and `curl -fsS --max-time 30`.

**P2-14 — `k8s/apps/ai/values.yaml` (`podApiKey: foo`) — model-pod `/metrics` auth key is a static committed literal**
In-cluster-only (ClusterIP), so low severity, but `foo` is in git — effectively unauthenticated for anyone with cluster access. Cross-ref domain-chart P2-4 (not duplicated here).
**Fix (per chart review):** move to the sops file / a Secret.

---

## Exposure surface

Every reachable port/endpoint created by this branch (single-node k3s, mjolnir; "LAN" = the trusted home subnet; traefik ingress has no TLS certs configured):

| Endpoint | Port / reachability | Service type | Ingress | Auth | Verdict |
|---|---|---|---|---|---|
| LiteLLM gateway `/v1` (OpenAI API) | hostPort **8000** (prod); 8001 test pod (currently `testPod: false`, inert) | hostPort → pod 4000 | none (direct hostPort) | minted virtual key (`usePostgresKeys: true`; `foo` no longer works) | OK — authenticated |
| LiteLLM gateway `/metrics` | hostPort **8000** (same binding) | hostPort | none | **NONE** (`require_auth_for_metrics_endpoint: false`) | **P1-1** — unauthenticated + LAN-reachable |
| LiteLLM `/health/readiness` | hostPort 8000 | hostPort | none | none | OK — low sensitivity (health only) |
| LiteLLM `/key/*` (mint/revoke) | hostPort 8000 | hostPort | none | master key (sops) | OK — authenticated |
| Grafana | 3000, ClusterIP | ClusterIP | traefik `grafana.mjolnir` (HTTP, no TLS) | admin + sops password (`monitoring-secrets` Secret) | OK w/ **P2-9** (cleartext password over LAN) |
| llama.cpp model pods `/metrics` | 8555/8556/8557, ClusterIP | ClusterIP | none | static `--api-key foo` (committed) | in-cluster only; **P2-14** |
| log-exporter sidecar `/metrics` | 9399, pod-only (PodMonitor) | none | none | none (plain http.server) | in-cluster only; acceptable, noted |
| Postgres (LiteLLM key store) | 5432, ClusterIP | ClusterIP | none | `POSTGRES_PASSWORD` from `litellm-keys` Secret (`secretKeyRef`) | OK — in-cluster, authenticated |
| Prometheus | 9090, ClusterIP | ClusterIP | none | none | in-cluster only; OK |
| Alertmanager | 9093, ClusterIP | ClusterIP | none | none | in-cluster only; OK |
| Loki | 3100, ClusterIP | ClusterIP | none | none (multi-tenant org header) | in-cluster only; OK |
| Alloy | DaemonSet, in-cluster | DaemonSet | none | n/a | OK |
| DCGM exporter | 9827, ClusterIP | ClusterIP | none | none | in-cluster only; pod is root+SYS_ADMIN → **P2-8** |
| node-exporter | 9100, hostNetwork | host | none | **none** | LAN-reachable (firewall) → **P2-6** |
| kubelet | 10250, hostNetwork | host | none | bearer token (system:node-reader) | LAN-reachable (firewall) → **P2-6** |
| k3s API server | 6443, host | host | none | TLS + token | pre-existing on main, unchanged |

Secret-to-k8s wiring (verified): sops file → sops-nix materialises `/run/secrets` at runtime (`sops.useSystemdActivation = false`, activation `deps = [setupSecrets]`) → activation script reads them and applies `litellm-keys` (default ns: `master-key`, `postgres-password`, `database-url`) and `monitoring-secrets` (monitoring ns: grafana creds) as proper K8s Secrets → pods consume via `secretKeyRef` only (gateway: `DATABASE_URL`+`LITELLM_MASTER_KEY`; postgres: `POSTGRES_PASSWORD`). No plaintext env, no ConfigMap-baked secrets, no values-file secrets (only the `foo` placeholder, P2-14). The `llm-api-key` Secret is derived from the rendered chart's static `podApiKey` (grep/sed chain — fragile, see ponytail L266-268, not a security issue). <!-- pragma: allowlist secret -->

## Per-file verdicts

| File | Verdict |
|---|---|
| `nix/services/homelab/homelab-secrets.yaml` | **LGTM** — every value `ENC[AES256_GCM]`, 3 age recipients, MAC present; the only place secrets live. Note: mjolnir recipient rotated this branch (see P1-4). |
| `.sops.yaml` | **LGTM** — creationRules scoped to the two exact sops file paths (anchored `$`), no broad patterns; all three recipients on both. |
| `.pre-commit-config.yaml` | **Findings** — P2-1 (unanchored `secrets.yaml` exclusion); kps-values exclusion verified harmless. |
| `scripts/mint-litellm-key.sh` | **Findings** — P1-2 (no idempotency), P1-3 (world-readable /tmp dump), P2-2…P2-5, P2-11, P2-13. Positives: `set -euo pipefail`, non-interactive, master key from sops (never hardcoded), sane master-key validation, `command -v sops` guard. |
| `docs/runbook-mint-litellm-key.md` | **Findings** — P1-4 (missing age-key/rotation/re-apply sections), P2-10 (misleading re-mint note), P2-12 (no commit step). Positives: mint/use/verify/list/revoke all covered with exact commands, troubleshooting table, test-pod vs prod distinction. |
| `nix/services/k3s.nix` (cross-ref) | **Findings** — P2-6 (firewall source-unrestricted), P2-7 (10y token); sops→Secret wiring itself is sound. |
| `k8s/apps/ai/templates/*` + `k8s/apps/monitoring/values/*` (cross-ref, exposure only) | **Findings** — P1-1 (unauth `/metrics`), P2-8 (DCGM root), P2-9 (Grafana HTTP), P2-14 (static `foo`). |

## Summary

The secret-handling backbone is solid: the sops file is fully age-encrypted with exact-path creation rules, it is the single source of truth, and every value reaches the cluster through sops-nix → K8s Secrets → `secretKeyRef` with no plaintext anywhere in the branch (verified by full diff + tree greps). The gaps are operational and exposure-side: the gateway's `/metrics` is unauthenticated on a LAN-reachable hostPort (P1-1); the mint script is not idempotent, dumps all decrypted secrets to a world-readable fixed /tmp path it never cleans up, and leaks secrets via argv/stderr (P1-2, P1-3, P2-2…P2-5); the runbook omits the three sections the research brief mandates — age key location/backup (acute, because this branch rotates the mjolnir age key), sops rotation, and exact re-apply commands (P1-4); and the detect-secrets exclusion is broader than the sops files (P2-1). The remaining P2s are LAN-hygiene items (cleartext HTTP, source-unrestricted firewall ports for node-exporter/kubelet, HTTP-only Grafana ingress, 10-year kubelet token, DCGM root pod) that are acceptable on a trusted single-subnet homelab once documented. No P0: nothing committed in plaintext, and no unauthenticated endpoint reaches a credential-bearing surface.
