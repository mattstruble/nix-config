# Domain Review: k8s/manifests + k3s.nix wiring

- **Ticket:** mestruble-3x7.10
- **Date:** 2026-01-22
- **Scope:**
  1. `k8s/manifests/local-pvs.yaml` (108 lines)
  2. `k8s/manifests/kubelet-monitoring.yaml` (30 lines)
  3. `k8s/manifests/nvidia-runtimeclass.yaml` (7 lines)
  4. `nix/services/k3s.nix` (311 lines)
  5. `justfile` (43 lines)
- **Method:** Single-pass read of each in-scope file, cross-checked against `k8s/apps/ai/values.yaml` + `k8s/apps/ai/values/*.yaml` + chart templates, `k8s/apps/monitoring/values/*.yaml`, and `docs/review/feat-observability/research.md` (sections 2.4, 5, 6). Skills loaded: k8s-storage, k3s. `cloud-model-rates.yaml` excluded (covered in domain-monitoring.md).

## Verified OK (cross-checks)

- **PV↔PVC↔chart binding:** `nix-store-pvc` (100Gi, ROX, sc `nix-store`) and `llama-models-pvc` (500Gi, ROX, sc `llama-models`) match `claimName` refs in `k8s/apps/ai/templates/model-deployment.yaml:185,195`; sizes equal on both sides. `postgres-data` PV (1Gi, RWO, sc `postgres-data`) matches the chart-rendered PVC (`templates/postgres-pvc.yaml`, size from `gateway.postgresDataSize: 1Gi`). All three PVs set `persistentVolumeReclaimPolicy: Retain` explicitly (research §2.4). ROX on single-node local PVs is valid (many pods, one node, read-only).
- **Monitoring storage:** kps (20Gi) and loki (10Gi) use `local-path` dynamic provisioning — no static PVs required; consistent with k3s default.
- **RuntimeClass:** `nvidia` (node.k8s.io/v1, GA) matches `runtimeClassName: nvidia` in `model-deployment.yaml:33` and the `nvidia` containerd runtime in `k3s.nix` `containerdConfigTemplate` (CDI binary).
- **Kubelet token wiring:** ServiceMonitor `authorization` → secret `kubelet-monitoring-token` key `token` in `monitoring` ns (kps values:32-38); activation mints the SA token and creates exactly that secret/key in that namespace.
- **Activation ordering:** PVs + RuntimeClass go via `services.k3s.manifests` (applied by k3s at service start, before activation scripts); `sops.useSystemdActivation = false` + `deps = ["setupSecrets"]` guarantees `/run/secrets` exists before the aiChart script reads it; secrets (`litellm-keys`, `monitoring-secrets`, `llm-api-key`) are created before the ai chart is applied. Rendered charts are exposed via `system.build.*` so they land in the closure. All correct.
- **justfile `deploy`/`lint`/`update`/`mint-key`:** match actual commands; `mint-key` delegates to `scripts/mint-litellm-key.sh`.

## Findings

### P0 (blocking)

(none)

### P1 (should fix)

1. **`nix/services/k3s.nix:244-295` — activation failure is swallowed (exit 0).** The retry loop ends with `echo "warning: chart apply failed after 60s" >&2`, which is the script's last command → the activation script exits 0. If the `&&` chain never succeeds (e.g. k3s API slow to come up, grep finds nothing — see P1-2), deploy-rs reports a **successful** deploy while kps, the dashboards, and the CRD apply were never applied. Fix: `exit 1` after the loop (and consider making the final echo non-terminal).
2. **`nix/services/k3s.nix:266-271` — `LLM_KEY` extraction is fragile and unguarded.** `grep -A1 -- '"--api-key"' … | head -1 | sed …` assumes the exact rendered YAML shape (quoted arg on one line, quoted value on the next). It works today — `model-deployment.yaml:89-90` is the only template rendering a literal `"--api-key"` arg, and all models share `podApiKey` — but a chart change (inline `--api-key=x`, rename, unquoted) yields an **empty** `LLM_KEY`, and `--from-literal=token=""` is applied silently → ai-fleet ServiceMonitor 401s with no error at deploy time. Fix: assert `[ -n "$LLM_KEY" ] || exit 1`, and preferably derive the key from the merged values (`yq .gateway.podApiKey`) instead of scraping rendered YAML.
3. **`nix/services/k3s.nix:275-290` — no `--prune`, no release state: removed resources are never deleted.** All charts are applied as plain `kubectl apply -f rendered.yaml` (no `--prune`, no Helm release, so no `helm uninstall` path). Disabling a model in `values/*.yaml`, turning off `gateway.testPod`, or dropping an `extraVolume` leaves the old Deployment/Service running (GPU/CPU leak, stale gateway routes). The three `prometheusrule` deletes at :289-292 are the only manual pruning. Fix: apply with a common label + `kubectl apply --prune -l <label>`, or switch to `helm upgrade --install` against the local chart (gives release state, `--prune`, and uninstall).

### P2 (nice to have)

4. **`nix/services/k3s.nix:212-214` — sed-based secret injection.** `sed "s|__TELEGRAM_BOT_TOKEN__|$TG_TOKEN|"` breaks if a value contains `|`, `&`, or `\`. Latent today (bot tokens are `[0-9A-Za-z_-]`, chat IDs numeric; the grafana password goes through `--from-literal`, not sed), but it's a footgun for the next secret. Fix: `envsubst` or a `yq` values merge.
5. **`k8s/manifests/kubelet-monitoring.yaml:20-24` — RBAC broader than needed; comment likely wrong.** The comment asserts "k3s has no system:node-reader", but `system:node-reader` is standard k8s RBAC (get on `nodes`, `nodes/proxy`, `nodes/metrics`) and k3s bootstraps it — verify with `k3s kubectl get clusterrole system:node-reader`. `system:kubelet-api-admin` grants **all verbs** on `nodes/proxy` (and metrics), broader than a scrape token needs. If node-reader exists, prefer it. Related: `k3s.nix:233` comment says "(system:node-reader)" while the manifest binds `system:kubelet-api-admin` — the two comments disagree.
6. **`nix/services/k3s.nix:287` — operator `rollout restart` on every activation.** Justified for fresh installs (operator only detects CRDs at startup), but on every subsequent deploy it needlessly restarts the kps operator (brief gap in Prometheus/Alertmanager/Grafana controller management). Fix: restart only when CRDs were newly created (e.g. check CRD existence before applying).
7. **`justfile:33-38` — render logic duplicated from k3s.nix; manual path skips secret refresh.** `k8s-render`/`k8s-deploy` re-implement the `F=(-f …)` loop from `aiChartRendered` (k3s.nix:27-34) — two copies will drift if a values source is added to one only. `k8s-deploy` applies only the ai chart and does **not** refresh the `llm-api-key` secret, so a `podApiKey` change made via the manual path breaks monitoring auth until the next full `just deploy`. Fix: one shared render script, or document the divergence + add the secret refresh to `k8s-deploy`.
8. **`k8s/manifests/local-pvs.yaml:27,51,79` — nodeAffinity hardcodes hostname `mjolnir`.** A node rename (or migration) orphans all three PVs (Retain keeps the data, but nothing can bind). Fix: select on a stable node label set in `k3s.nix` (e.g. `node.kubernetes.io/instance` won't help — use a custom label like `storage=mjolnir`).
9. **`nix/services/k3s.nix:302` — firewall opens 10250 to all sources.** Kubelet metrics port is reachable from the whole LAN; mitigated by bearer-token auth, but any LAN host can probe/brute the endpoint. Fix: restrict the source to the pod CIDR (nftables rule) if the firewall module allows.
10. **`justfile:18-19` — dual deploy paths.** `copy $host` rsyncs the repo to `/etc/nixos` (impure, non-flake) while `deploy $host` uses deploy-rs against the flake. Both work, but they can diverge (post-deploy steps, secret handling) and it's unclear which is canonical for mjolnir. Fix: mark one deprecated or document when each is used.

## Per-file verdicts

- `k8s/manifests/local-pvs.yaml`: **findings** — P2-8 (hostname pinning). Otherwise LGTM: names/sizes/accessModes/storageClassName/reclaimPolicy/nodeAffinity all correct and consistent with the ai chart.
- `k8s/manifests/kubelet-monitoring.yaml`: **findings** — P2-5 (RBAC scope + comment accuracy).
- `k8s/manifests/nvidia-runtimeclass.yaml`: **LGTM** — name/handler/apiVersion all correct; matches chart `runtimeClassName` and containerd runtime.
- `nix/services/k3s.nix`: **findings** — P1-1 (swallowed failure), P1-2 (LLM_KEY grep), P1-3 (no --prune), P2-4 (sed), P2-6 (rollout restart), P2-9 (firewall 10250).
- `justfile`: **findings** — P2-7 (duplicated render logic / stale secret on manual path), P2-10 (dual deploy paths).

## Summary

The wiring is fundamentally sound: PV/PVC/chart names, sizes, and storage classes all line up (including the chart-rendered `postgres-data` PVC), the RuntimeClass and containerd runtime match, the kubelet token secret is minted with exactly the name/key/namespace the kps ServiceMonitor references, and activation ordering is correct (k3s `manifests` → `setupSecrets` → secrets → charts, with rendered charts pinned into the system closure via `system.build.*`). The real risks are operational, not correctness-of-state: the activation script exits 0 when the 60s retry loop fails (P1-1), the `llm-api-key` extraction is an unguarded grep over rendered YAML (P1-2), and the apply-only-no-prune pattern leaks resources when values shrink (P1-3). The rest are hygiene items: over-broad kubelet RBAC with a likely-wrong comment, sed-injected secrets, a per-deploy operator restart, duplicated render logic in the justfile, and a hostname-pinned PV affinity.
