# Synthesis Report: feat/observability

- **Epic:** mestruble-3x7
- **Date:** 2026-10-04
- **Branch:** `feat/observability` (repo `/Users/mestruble/Software/nix-config`)
- **Method:** 9 review passes, deduplicated into this report:
  1. `research.md` — best-practices brief (context/reference only; no findings of its own)
  2. `ponytail-review.md` — over-engineering review of the branch diff (7 findings)
  3. `ponytail-audit.md` — ranked over-engineering audit (13 findings)
  4. `ponytail-debt.md` — `ponytail:` marker ledger (6 markers; no findings — reproduced in "Ponytail debt")
  5. `domain-chart.md` — ai Helm chart + values review (1 P0, 3 P1, 13 P2)
  6. `domain-dashboards.md` — Grafana dashboards review (2 P0, 3 P1, 9 P2)
  7. `domain-monitoring.md` — PrometheusRule + monitoring values review (3 P1, 10 P2)
  8. `security-ops.md` — security/ops audit (4 P1, 14 P2)
  9. `domain-manifests.md` — k8s/manifests + k3s.nix wiring review (3 P1, 7 P2)

Raw findings across the 8 finding-producing passes: **72 P0/P1/P2-grade (3 P0 + 16 P1 + 53 P2) + 20 ponytail items = 92**; after deduplication (17 items merged into existing entries): **2 P0, 15 P1, 58 P2 = 75 entries**.

Dedup rule applied: the same underlying problem reported by two or more passes becomes one entry with all source passes noted. Cross-pass merges:

| Merged entry | Sources |
|---|---|
| P0-1 (log-exporter sidecar) | domain-chart P0-1 + ponytail-audit #3 + ponytail-review (log-exporter-configmap L50-51) |
| P0-2 (llm-fleet throughput panels) | domain-dashboards P0-1 + P0-2 + P1-1 |
| P1-6 (LLM_KEY grep) | domain-manifests P1-2 + ponytail-review (k3s.nix L266-268) + ponytail-audit #10 |
| P1-7 (no `--prune`) | domain-manifests P1-3 + domain-chart P2-13 |
| P2-4 (podApiKey `foo`) | domain-chart P2-4 + security-ops P2-14 |
| P2-15 (dashboard auto-refresh) | domain-dashboards P2-3 + P2-4 + P2-5 |
| P2-25 (over-broad monitor selectors) | domain-monitoring F-P2-6 + F-P2-7 |
| P2-34 (firewall 9100/10250) | security-ops P2-6 + domain-manifests P2-9 |
| P2-45 (justfile manual chart path) | domain-manifests P2-7 + ponytail-audit #11 |
| P2-48 (dead testpod machinery) | ponytail-audit #4 + ponytail-review (3 items) |
| P2-49 (fork-binary mechanism) | ponytail-audit #5 + ponytail-review (model-deployment L4-5) |

Note: `research.md` is the best-practices brief used as the reference baseline by the domain passes; it contributes no findings. `ponytail-debt.md` is the marker ledger, reproduced verbatim in the "Ponytail debt" section.

---

## Findings

### P0

**P0-1 — log-exporter sidecar truncates a log it mounts read-only (tail thread dies after 100 MiB); the whole sidecar re-derives metrics llama.cpp already exposes natively**
- `k8s/apps/ai/templates/model-deployment.yaml:174` (exporter `log` volumeMount `readOnly: true`), `k8s/apps/ai/templates/log-exporter-configmap.yaml:50` (`with open(LOG_FILE, "w"): pass` rotation, uncaught `PermissionError` at :66), `k8s/apps/ai/templates/model-deployment.yaml:188` (emptyDir `sizeLimit: 200Mi`).
- Problem: the exporter's rotation raises EROFS on a read-only mount, killing the daemon tail thread permanently after ~100 MiB of model log — live decode/prefill gauges freeze and stdout → Alloy → Loki stops; the unrotated log then fills the 200 Mi emptyDir and the model's own `>> /var/log/llama.log` writes fail with ENOSPC. Independently, the sidecar exists only to re-derive live decode/prefill rates that llama.cpp already exposes as `llamacpp:predicted_tokens_seconds` / `llamacpp:prompt_tokens_seconds` gauges (see `llama-metrics.md`).
- Fix: delete the sidecar, the `sh -c` log-redirect wrapper, the log emptyDir, and the `llm-log-exporter` PodMonitor; point the dashboard's live-status table at the native gauges (model stdout then flows through the container-runtime log Alloy already collects). Minimal alternative if the sidecar is kept: drop `readOnly: true` from the exporter's `log` volumeMount and use `os.truncate(LOG_FILE, 0)`; verify with a forced >100 MiB log.
- Sources: domain-chart P0-1; ponytail-audit #3; ponytail-review (log-exporter-configmap.yaml L50-51).

**P0-2 — llm-fleet panels 128/129 ("Decode tokens/s", "Prompt tokens/s (prefill)") query metrics and a label that do not exist → render empty**
- `k8s/apps/monitoring/dashboards/llm-fleet.json:97` (panel 128: `sum by (model) (llamacpp_live_decode_tps{model=~"$model"})`), `llm-fleet.json:177` (panel 129: `sum by (model) (llamacpp_live_prefill_tps{model=~"$model"})`), legendFormat :98/:178.
- Problem: `llamacpp_live_decode_tps` / `llamacpp_live_prefill_tps` are not real metrics (live-captured names are the gauges `llamacpp:predicted_tokens_seconds` / `llamacpp:prompt_tokens_seconds`), and model-pod metrics carry no `model` label at all (only `job`/`instance`), so `model=~"$model"` matches nothing and `sum by (model)` would yield one empty series even with correct names. Every other llamacpp panel in the dashboard correctly uses `job=~"$model"`.
- Fix: panel 128 → `"expr": "sum by (job) (llamacpp:predicted_tokens_seconds{job=~\"$model\"})"`; panel 129 → `"expr": "sum by (job) (llamacpp:prompt_tokens_seconds{job=~\"$model\"})"`.
- Sources: domain-dashboards P0-1, P0-2, P1-1 (merged — one underlying problem: both headline throughput panels written against a nonexistent metric/label pair).

### P1

**P1-1 — gateway `/metrics` is unauthenticated and LAN-reachable via hostPort 8000**
- `k8s/apps/ai/templates/gateway-configmap.yaml:25` (`require_auth_for_metrics_endpoint: false`) + gateway `hostPort: 8000` (DNAT'd straight to the pod, bypassing the host firewall).
- Problem: `http://mjolnir:8000/metrics` serves spend/token/latency metrics to anyone on the LAN with no credential. The in-cluster ServiceMonitor scrape uses the ClusterIP Service and does not need the hostPort. (domain-chart called this setting "acceptable: ClusterIP-only" — the hostPort exposure supersedes that verdict.)
- Fix: set `require_auth_for_metrics_endpoint: true`, mint a dedicated metrics key (`just mint-key metrics`) into the `litellm-keys` Secret, and point the `ai-fleet` monitor's `bearerTokenFile` at it (the current `llm-api-key` token `foo` is a llama.cpp pod key, not a valid gateway key — enabling auth with it would 401 the gateway scrape).
- Sources: security-ops P1-1.

**P1-2 — `scripts/mint-litellm-key.sh` is not idempotent: no check-for-existing before create**
- `scripts/mint-litellm-key.sh:24-27`.
- Problem: re-running `just mint-key pi` POSTs to `/key/generate` unconditionally and fails with `Key with alias 'pi' already exists`; exactly the failure mode after a partial run (mint succeeded, sops write failed).
- Fix: `GET $GATEWAY/key/info` (master key) and check for `key_alias == $NAME`; if it exists, print the key from the sops copy and exit 0; if the sops copy is missing, fail with a clear "revoke first" message.
- Sources: security-ops P1-2.

**P1-3 — mint script writes ALL decrypted secrets to a fixed, world-readable temp file that is never deleted**
- `scripts/mint-litellm-key.sh:37-40` (`sops decrypt "$F" > /tmp/hl-plain.yaml`).
- Problem: the entire decrypted secrets file (grafana password, telegram token, master key, postgres password, all minted keys) lands in a predictable world-readable path and is left behind after exit — any local user can read every homelab secret from `/tmp`. The `k3s.nix` activation script does this correctly (`mktemp -d` + `trap 'rm -rf' EXIT`).
- Fix: `umask 077; T="$(mktemp)"; trap 'rm -f "$T"' EXIT; sops decrypt "$F" > "$T"` and operate on `$T`.
- Sources: security-ops P1-3.

**P1-4 — runbook missing the three sections the research brief mandates (age key location/backup, sops rotation, exact re-apply commands)**
- `docs/runbook-mint-litellm-key.md`.
- Problem: (a) no age-key location/backup section — acute because this branch **rotates the mjolnir recipient** in `.sops.yaml` (`age1m8d99…` → `age1ng45h…`) and re-encrypts the sops file: if the new private key isn't installed on mjolnir before deploy, the cluster cannot decrypt `/run/secrets` and every secret-fed component breaks with no documented recovery path; (b) no `sops updatekeys`/re-encryption procedure; (c) no statement that `just deploy mjolnir` / `nixos-rebuild switch --flake .#mjolnir` is what ships a changed sops value.
- Fix: add a "Secrets & age keys" section: key locations per machine + backup method, `sops updatekeys nix/services/homelab/homelab-secrets.yaml` after rotation, and "after editing the sops file: `git commit` + `just deploy mjolnir`".
- Sources: security-ops P1-4.

**P1-5 — activation failure is swallowed: the aiChart script exits 0 when the 60 s retry loop fails**
- `nix/services/k3s.nix:244-295` (loop ends with `echo "warning: chart apply failed after 60s" >&2` as the last command).
- Problem: if the `&&` chain never succeeds (k3s API slow, grep finds nothing — see P1-6), deploy-rs reports a **successful** deploy while kps, the dashboards, and the CRD apply were never applied.
- Fix: `exit 1` after the loop.
- Sources: domain-manifests P1-1.

**P1-6 — `LLM_KEY` extraction is an unguarded grep/sed over rendered YAML → empty key silently breaks monitoring auth**
- `nix/services/k3s.nix:266-271` (`grep -A1 -- '"--api-key"' … | head -1 | sed …`).
- Problem: assumes the exact rendered YAML shape (quoted arg on one line, quoted value on the next). A chart change (inline `--api-key=x`, rename, unquoted) yields an empty `LLM_KEY`, `--from-literal=token=""` is applied silently, and the ai-fleet ServiceMonitor 401s with no error at deploy time.
- Fix: assert `[ -n "$LLM_KEY" ] || exit 1`, and derive the key from the merged values (`${pkgs.yq}/bin/yq -r '.gateway.podApiKey' …/values.yaml`) instead of scraping rendered YAML.
- Sources: domain-manifests P1-2; ponytail-review (k3s.nix L266-268); ponytail-audit #10.

**P1-7 — no `--prune`, no release state: removed resources are never deleted**
- `nix/services/k3s.nix` (all charts applied as plain `kubectl apply -f rendered.yaml`); symptom: `k8s/apps/ai/templates/gateway-testpod.yaml:5` comment claims "helm/kubectl apply prunes it" — false, the script runs no `--prune`.
- Problem: disabling a model in `values/*.yaml`, turning off `gateway.testPod`, or dropping an `extraVolume` leaves the old Deployment/Service running (GPU/CPU leak, stale gateway routes); setting `testPod: false` leaves the `litellm-test` Deployment (and hostPort 8001) in the cluster until manually deleted. The three `prometheusrule` deletes at k3s.nix:289-292 are the only manual pruning.
- Fix: apply with a common label + `kubectl apply --prune -l <label>`, or switch to `helm upgrade --install` against the local chart (release state, `--prune`, uninstall); correct the testpod comment (or the testpod goes away entirely via P2-48).
- Sources: domain-manifests P1-3; domain-chart P2-13.

**P1-8 — log-exporter sidecar has no container securityContext → pod fails PSS restricted**
- `k8s/apps/ai/templates/model-deployment.yaml:151-179` (the `log-exporter` container has no `securityContext` block).
- Problem: pod-level `runAsUser: 1000` covers non-root, but PSS "restricted" additionally requires per-container `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile.type: RuntimeDefault`. Every other container in the chart sets these; the sidecar doesn't, so the whole pod is non-compliant.
- Fix: add the same container-level block the `llama-server` container uses (model-deployment.yaml:70-78). (Moot if the sidecar is deleted per P0-1.)
- Sources: domain-chart P1-1.

**P1-9 — enabled images are tag-pinned, not digest-pinned**
- `k8s/apps/ai/values/gemma-4-26b-a4b.yaml:4`, `values/swift-qwen3-8-27b.yaml:7` (the two *enabled* models), `values.yaml:25` (`ghcr.io/berriai/litellm:v1.102.1`), `values.yaml:28` (`postgres:16-alpine` — floating minor tag).
- Problem: the chart's own header (`values.yaml:5`) documents "image: digest-pinned" and 4 of 8 model entries comply — the two that are actually running don't; `postgres:16-alpine` can silently change minor version on re-pull.
- Fix: pin all four with `@sha256:` digests (`docker buildx imagetools inspect <ref>`); at minimum pin postgres to an exact tag (e.g. `16.4-alpine3.20`).
- Sources: domain-chart P1-2.

**P1-10 — startupProbe budget is hard-coded for all models (300 s), can't be extended for 125B-class models**
- `k8s/apps/ai/templates/model-deployment.yaml:107-112` (`failureThreshold: 30` × `periodSeconds: 10`, fixed in the template; comment at :104 sizes it for a "20GB load").
- Problem: the flash-next entries (`values/qwen3-8-flash-next.yaml`, `values/qwen3-8-flash-next-256k.yaml` — 125B-class, 8 Gi request / 80 Gi limit, cold experts on CPU) can plausibly exceed 5 min to load; a failed startupProbe kills the container mid-load → CrashLoop. Because the budget lives in the template, no per-model values file can extend it.
- Fix: move startupProbe params into per-model values (`startupProbe: {periodSeconds, failureThreshold}` with chart defaults) and give flash-next a larger budget.
- Sources: domain-chart P1-3.

**P1-11 — `k8s/apps/ai/templates/llama-metrics.yaml` does not exist (ticket-scope artifact missing; wiring split across files)**
- `k8s/apps/ai/templates/llama-metrics.yaml` (absent; `git log --all` empty).
- Problem: the ticket lists this file in scope, but the llama.cpp metrics wiring is embedded in `k8s/apps/monitoring/values/kube-prometheus-stack.yaml` (`additionalServiceMonitors: ai-fleet`, `additionalPodMonitors: llm-log-exporter`) — functionality is covered, but the expected artifact is missing and the wiring is split across files.
- Fix: either create the dedicated ServiceMonitor in the ai chart and drop the model-pod portion of the kps `ai-fleet` monitor, or confirm the consolidated-in-kps-values design is intentional and update the ticket scope. No functional breakage today.
- Sources: domain-monitoring F-P1-1.

**P1-12 — per-token cost is not a recording rule; the math is inlined and duplicated verbatim in two dashboard panels**
- `k8s/manifests/cloud-model-rates.yaml` (records only the price constants) + `k8s/apps/monitoring/dashboards/llm-overview.json` ("Est. cloud cost avoided (range)" and "Net savings (range)" panels duplicate the ~300-char expression).
- Problem: the research brief requires `cost = tokens × unit_price` as a recording rule so dashboards read the result; any formula change (e.g. a new token_type) must be made in two places. (Metric names in the cost math are correct — all match the live-verified catalog with `_total` suffixes.)
- Fix: add a recording rule to the existing rule file, e.g. `record: ai:litellm:cost:increase1h` over `(increase(litellm_input_tokens_metric_total[1h]) - increase(litellm_input_cached_tokens_metric_total[1h]))/1e6 * cloud_model_rates{token_type="input"} + …` (1-to-many vector match on `profile`); at minimum extract the shared expression into one place.
- Sources: domain-monitoring F-P1-2.

**P1-13 — DCGM values: no explicit GPU scheduling (nodeSelector/affinity)**
- `k8s/apps/monitoring/values/dcgm-exporter.yaml` (whole file).
- Problem: GPU-node scheduling relies entirely on the NVIDIA chart's default `nodeSelector` (`nvidia.com/gpu.present: "true"`); the intent is invisible in the values and will silently break if the chart default changes or a second, non-GPU node is added (exporter scheduled off-GPU → no metrics, no alert).
- Fix: add `nodeSelector: {nvidia.com/gpu.present: "true"}` (or `affinity` on `nvidia.com/gpu` Exists — verify against `kubectl get nodes --show-labels` on mjolnir).
- Sources: domain-monitoring F-P1-3.

**P1-14 — llm-fleet panel 134 "MTP acceptance" divides raw cumulative counters**
- `k8s/apps/monitoring/dashboards/llm-fleet.json:517`.
- Problem: `sum(…spec_decode_num_accepted_tokens_total) / sum(…spec_decode_num_draft_tokens_total)` is a ratio of cumulative counters since process start, not the current acceptance rate (and it drifts as the counters age).
- Fix: `"expr": "sum by (job) (rate(llamacpp:spec_decode_num_accepted_tokens_total{job=~\"$model\"}[5m])) / sum by (job) (rate(llamacpp:spec_decode_num_draft_tokens_total{job=~\"$model\"}[5m]))"`.
- Sources: domain-dashboards P1-2.

**P1-15 — `percentunit` unit on raw core values in 3 cluster-overview CPU panels (misleading numbers, stacked totals >100%)**
- `k8s/apps/monitoring/dashboards/cluster-overview.json:914,1168,1262` (panels 116 "CPU use by namespace" expr :948, 120 "Pods CPU usage" expr :1202, 122 "Containers CPU usage" expr :1296).
- Problem: all plot `sum(rate(container_cpu_usage_seconds_total[5m])) by (…)`, which yields **cores**, but the field unit is `percentunit` (0–1 = 0–100%): a pod using 0.5 cores displays as 50%; on a multi-core node the stacked panel 116 totals far above 100%.
- Fix (per panel): divide by core count (e.g. panel 116: `… / sum(machine_cpu_cores{node=~"^$Node$"})`, keep `percentunit`), or change the unit to `short` and rename the panels "(cores)".
- Sources: domain-dashboards P1-3.

### P2

**P2-1 — no CPU requests/limits on any ai-chart container; log-exporter has no resources at all**
- `k8s/apps/ai/templates/model-deployment.yaml:148-152` (memory only), `gateway-deployment.yaml:81-84`, `postgres-deployment.yaml:59-62`, `model-deployment.yaml:151-179` (exporter: none).
- Problem: memory is set everywhere; CPU is nowhere, so the exporter is BestEffort and the rest Burstable.
- Fix: add CPU requests (e.g. 500m gateway, 250m postgres, 100m exporter); CPU limits are legitimately skippable for inference workloads — if skipped, say so in a comment.
- Sources: domain-chart P2-1.

**P2-2 — no `values.schema.json`**
- Chart root (`k8s/apps/ai/`).
- Problem: typos in per-model keys (`memoryReqest`, `chatTemplte`) render `null` and surface later as cryptic `kubectl apply` validation errors instead of failing fast at render time.
- Fix: add `values.schema.json` covering `models.*` (`enable`, `image`, `gpu`, `port`, `modelName`, `memoryRequest`, `memoryLimit`, `args`, `nixBinary`, `command`, `chatTemplate`, `extraVolumes`, `extraMounts`) and the `gateway.*` keys.
- Sources: domain-chart P2-2.

**P2-3 — no `_helpers.tpl`; non-standard label set**
- All `k8s/apps/ai/templates/*` (labels inlined per resource).
- Problem: reusable logic (labels, image ref) should live in named templates; the chart only emits `app: <name>` + `app.kubernetes.io/part-of: ai`, missing `app.kubernetes.io/name` and `app.kubernetes.io/managed-by`.
- Fix: add `_helpers.tpl` with `ai.labels`/`ai.selectorLabels` and the standard labels.
- Sources: domain-chart P2-3.

**P2-4 — pod API key `foo` is a static committed literal in values, in container args, and in a ConfigMap**
- `k8s/apps/ai/values.yaml:27` (`podApiKey: foo`), `templates/model-deployment.yaml:89-90` (`--api-key` as a container arg → visible in pod spec/etcd/`kubectl get deploy -o yaml`), `templates/gateway-configmap.yaml:17`.
- Problem: sensitive values belong in Secrets referenced via `secretKeyRef`; the current value is a documented LAN-only placeholder so risk is low, but the pattern (key in args + scraping rendered YAML for it, see P1-6) is fragile.
- Fix: move the key into the sops-managed `litellm-keys` Secret, pass it via `secretKeyRef` (env), and point the monitoring scrape at the same Secret.
- Sources: domain-chart P2-4; security-ops P2-14.

**P2-5 — gateway `api_base` hard-codes the `default` namespace**
- `k8s/apps/ai/templates/gateway-configmap.yaml:16` (`http://{{ $name }}.default.svc.cluster.local:{{ $m.port }}/v1`).
- Problem: the chart has no namespace value and is pinned to `default`; moving the fleet to a dedicated namespace requires editing the template.
- Fix: add a `namespace` value (default `default`) and interpolate it.
- Sources: domain-chart P2-5.

**P2-6 — no `timeoutSeconds` on any probe (all default to 1 s)**
- `k8s/apps/ai/templates/model-deployment.yaml:107-117`, `gateway-deployment.yaml:75-80`, `postgres-deployment.yaml:53-57`.
- Problem: llama-server's `/health` can be slow under heavy load; a 1 s timeout causes spurious readiness flaps → gateway 502s mid-burst.
- Fix: `timeoutSeconds: 5` on the model probes (3 is fine for gateway/postgres).
- Sources: domain-chart P2-6.

**P2-7 — model `/dev/shm` is a 32 Gi tmpfs**
- `k8s/apps/ai/templates/model-deployment.yaml:214-216` (`medium: Memory`, `sizeLimit: 32Gi`).
- Problem: tmpfs counts against node RAM; llama.cpp's default shared-memory use is small, so a 32 Gi cap per model pod is a large single-node exposure if several models run.
- Fix: size to observed usage (2–4 Gi) or make it a per-model value.
- Sources: domain-chart P2-7.

**P2-8 — hard-coded ports not overridable via values**
- `k8s/apps/ai/templates/gateway-testpod.yaml:45` (hostPort 8001), `templates/model-deployment.yaml:167,170` (exporter port 9399 in both env and containerPort).
- Problem: every overridable knob belongs in values; these are baked into templates.
- Fix: `gateway.testPodPort` and `logExporter.port` values.
- Sources: domain-chart P2-8.

**P2-9 — gateway has no livenessProbe and no terminationGracePeriodSeconds**
- `k8s/apps/ai/templates/gateway-deployment.yaml` (readiness only; default 30 s grace).
- Problem: a wedged LiteLLM is never restarted, and 30 s may cut off in-flight generations (the model pods deliberately set 120 s for exactly this reason, model-deployment.yaml:44-46).
- Fix: liveness on `/health/liveliness` + `terminationGracePeriodSeconds: 120`.
- Sources: domain-chart P2-9.

**P2-10 — postgres container lacks `readOnlyRootFilesystem`**
- `k8s/apps/ai/templates/postgres-deployment.yaml:34-39`.
- Problem: not a PSS-restricted violation (baseline is met), but the research brief wants it as a chart default; the image needs `/var/run/postgresql` and `/tmp`.
- Fix: add `readOnlyRootFilesystem: true` plus small `emptyDir`s for `/var/run/postgresql` and `/tmp`.
- Sources: domain-chart P2-10.

**P2-11 — exporter HTTP server is single-threaded**
- `k8s/apps/ai/templates/log-exporter-configmap.yaml` (`HTTPServer(...).serve_forever()`).
- Problem: one slow scrape blocks all subsequent scrapes (Prometheus scrape timeout churn).
- Fix: `ThreadingHTTPServer`. (Moot if the sidecar is deleted per P0-1.)
- Sources: domain-chart P2-11.

**P2-12 — comment claims this k3s build rejects pod-level `readOnlyRootFilesystem`**
- `k8s/apps/ai/templates/model-deployment.yaml:56-60`, `gateway-deployment.yaml:38-40`.
- Problem: `PodSecurityContext.readOnlyRootFilesystem` has been standard since k8s 1.14; "unknown-field rejection" on k3s 1.35 is implausible. If client-side apply is pruning the field, the container-level placement is silently masking it.
- Fix: verify with `kubectl get pod -o yaml` on the cluster; if the field survives at pod level, move it up.
- Sources: domain-chart P2-12.

**P2-13 — llm-fleet `model` variable is job-based but labeled "Model (pod)"**
- `k8s/apps/monitoring/dashboards/llm-fleet.json:1618–1626`.
- Problem: `label_values(llamacpp:tokens_predicted_total, job)` yields job/service names; the label is misleading and is the root cause of the P0-2 label mismatches in panels 128/129.
- Fix: rename the variable label to "Model (job)" (and keep all queries on `job`), or define it from pod names if per-pod semantics are wanted.
- Sources: domain-dashboards P2-1.

**P2-14 — Loki "Model logs" panel with `$model`=All matches every pod in the namespace**
- `k8s/apps/monitoring/dashboards/llm-fleet.json:1602`.
- Problem: `{namespace="default", pod=~"($model).*"}` with `allValue: ".*"` becomes `pod=~"(.*).*"` — the panel also shows postgres/gateway logs.
- Fix: anchor to the model-pod prefix, e.g. `{namespace="default", pod=~"($model)-.*"}` (pods are `<model>-<rs>-<hash>`).
- Sources: domain-dashboards P2-2.

**P2-15 — no auto-refresh on any of the 3 dashboards (2 missing the key, 1 explicitly disabled)**
- `k8s/apps/monitoring/dashboards/cluster-overview.json` (no top-level `refresh`), `llm-fleet.json` (no top-level `refresh`), `llm-overview.json:1325` (`"refresh": ""` on a "live command center" that ships a `timepicker.refresh_intervals` list).
- Problem: auto-refresh is off on all three live dashboards.
- Fix: add `"refresh": "30s"` (or `"1m"` for llm-overview) at top level in each.
- Sources: domain-dashboards P2-3, P2-4, P2-5 (merged — one underlying problem across the three files).

**P2-16 — llm-overview has a hardcoded dashboard `"id"`**
- `k8s/apps/monitoring/dashboards/llm-overview.json:22` (`"id": 3238731674816512`; the other two use `"id": null`).
- Problem: a fixed DB id in a file-provisioned dashboard risks id collisions on import/provision (Grafana matches by `uid`; `id` should be assigned by the instance).
- Fix: `"id": null`.
- Sources: domain-dashboards P2-6.

**P2-17 — cluster-overview "Network I/O" panel only shows receive**
- `k8s/apps/monitoring/dashboards/cluster-overview.json:1037` (panel 118, single target `container_network_receive_bytes_total`).
- Problem: the title promises I/O both ways.
- Fix: add a second target: `sum(rate(container_network_transmit_bytes_total{node=~"^$Node$"}[5m]))`, legend "Transmitted".
- Sources: domain-dashboards P2-7.

**P2-18 — cluster-overview "Node Status" panel uses `kube_node_info` (scrape liveness, not readiness)**
- `k8s/apps/monitoring/dashboards/cluster-overview.json:89`.
- Problem: `kube_node_info` is 1 whenever node-exporter is scraped — it indicates scrape liveness, not node readiness.
- Fix: `"expr": "kube_node_status_condition{condition=\"Ready\"}"` (1 = Ready, 0 = NotReady) with the existing 0/1 thresholds; keep `legendFormat: "{{node}}"`.
- Sources: domain-dashboards P2-8.

**P2-19 — cluster CPU gauge includes pause containers (missing `image!=""` filter)**
- `k8s/apps/monitoring/dashboards/cluster-overview.json:172`.
- Problem: `sum(rate(container_cpu_usage_seconds_total{node=~"^$Node$"}[5m]))` lacks the `image!=""` filter every other container-CPU panel in the dashboard uses (pause-container CPU ≈ 0 — consistency only).
- Fix: `sum(rate(container_cpu_usage_seconds_total{image!="",node=~"^$Node$"}[5m]))`.
- Sources: domain-dashboards P2-9.

**P2-20 — recording rule name violates the namespace-prefix / `:` convention**
- `k8s/manifests/cloud-model-rates.yaml:32` (all 15 rules, `record: cloud_model_rates`).
- Problem: no namespace prefix, no `:` separators (convention: `ai:litellm:cost:rate5m`).
- Fix: rename to `ai:cloud_model:rates` (keep the shared-name/different-label-sets pattern — legal and documented in the file header); coordinated update of `llm-overview.json` (queries + `$rate_profile`) and the "Cloud model rates" section of `llama-metrics.md`.
- Sources: domain-monitoring F-P2-1.

**P2-21 — hardcoded cloud prices will go stale with no runbook**
- `k8s/manifests/cloud-model-rates.yaml:9` ("Rates as of 2026-07").
- Problem: provider price changes silently skew the "Est. cloud cost avoided" panel; no update procedure documented.
- Fix: extend the file header comment with the update procedure: edit the `vector(...)` constants, `k3s kubectl apply -f k8s/manifests/cloud-model-rates.yaml` (or `just deploy mjolnir`), and update the table in `llama-metrics.md`.
- Sources: domain-monitoring F-P2-2.

**P2-22 — scope note: `k8s/apps/monitoring/prometheus-rule.yaml` does not exist**
- The ticket names this file, but the branch contains exactly one PrometheusRule, `k8s/manifests/cloud-model-rates.yaml` (grep-verified; applied in the `k3s.nix` activation script).
- Problem: the ticket's filename was a guess; the real file was reviewed.
- Fix: none functionally — update the ticket scope to point at `k8s/manifests/cloud-model-rates.yaml`.
- Sources: domain-monitoring F-P2-3.

**P2-23 — kps values header comment is stale (build-time vs activation-time)**
- `k8s/apps/monitoring/values/kube-prometheus-stack.yaml:3-4`.
- Problem: header says "RENDERED AT BUILD TIME … (see nix/services/k3s.nix -> kpsValuesRendered)", but `k3s.nix` renders kps in the **activation script** (k3s.nix:44-50 says exactly this) and no `kpsValuesRendered` variable exists.
- Fix: rewrite the header to "RENDERED AT ACTIVATION TIME: `__TELEGRAM_BOT_TOKEN__` / `__TELEGRAM_CHAT_ID__` are substituted from sops in the activation script (nix/services/k3s.nix -> system.activationScripts.aiChart). Do not commit real tokens."
- Sources: domain-monitoring F-P2-4.

**P2-24 — stale comment: "DCGM is deployed in a later ticket"**
- `k8s/apps/monitoring/values/kube-prometheus-stack.yaml:71`.
- Problem: DCGM is deployed in this branch (`dcgmChartRendered` applied in the same activation script); the comment ("the monitor is harmless (no targets) until the dcgm-exporter Service exists") is no longer true.
- Fix: replace with "DCGM exporter is deployed in the same activation script; this monitor picks up its Service (`app.kubernetes.io/name: dcgm-exporter`, port `metrics`)."
- Sources: domain-monitoring F-P2-5.

**P2-25 — `ai-fleet` ServiceMonitor and `llm-log-exporter` PodMonitor selectors are broader than intended (match postgres/gateway)**
- `k8s/apps/monitoring/values/kube-prometheus-stack.yaml:95-100` (ServiceMonitor `app.kubernetes.io/part-of: ai` matches the postgres Service, whose single port 5432 is unnamed), `:113-117` (PodMonitor matches litellm + postgres pods too).
- Problem: prometheus-operator silently skips the unresolvable endpoints (no target, no down alert), so it's harmless today — but the selectors advertise coverage they don't have and will surprise anyone adding a port-named Service later.
- Fix: add a distinguishing label (e.g. `app.kubernetes.io/component: llm` on the model + gateway Services, `component: model` on the model pod template) and narrow both `matchLabels` to it.
- Sources: domain-monitoring F-P2-6, F-P2-7 (merged — same selector-hygiene problem, same fix).

**P2-26 — LiteLLM metrics scrape relies on a 307 redirect (`/metrics` → `/metrics/`)**
- `k8s/apps/monitoring/values/kube-prometheus-stack.yaml:98` (`path: /metrics`); `llama-metrics.md` documents the gateway endpoint as `/metrics/` — "note trailing slash, 307 without it".
- Problem: the shared `ai-fleet` endpoint scrapes `/metrics` for the litellm Service too; it only works because Prometheus follows redirects. A future LiteLLM change (or a client that doesn't follow redirects) breaks the gateway scrape with no local signal.
- Fix: split the `ai-fleet` monitor into two endpoints/monitors — `litellm` with `path: /metrics/` and the model Services with `path: /metrics` (both keep `bearerTokenFile: /prometheus/llm-api-key/token`; the gateway ignores the token per `require_auth_for_metrics_endpoint: false`).
- Sources: domain-monitoring F-P2-8.

**P2-27 — DCGM: no `customMetrics` KPI list (chart default ~40-field list exported)**
- `k8s/apps/monitoring/values/dcgm-exporter.yaml` (whole file).
- Problem: the dashboards only plot 7 DCGM fields (`DCGM_FI_DEV_GPU_UTIL`, `_FB_USED`, `_FB_FREE`, `_MEMORY_TEMP`, `_POWER_USAGE`, `_SM_CLOCK`, `_MEM_CLOCK`), all in the default list — nothing is missing, only excess series.
- Fix: add a `customMetrics` list with just those 7 fields (verify field IDs against the node's driver/CDI mode).
- Sources: domain-monitoring F-P2-9.

**P2-28 — no explicit `resources` on any monitoring stack component**
- `values/kube-prometheus-stack.yaml` (no `prometheus.prometheusSpec.resources` / `grafana.resources`), `values/loki.yaml` (no `singleBinary.resources`), `values/alloy.yaml` (no `alloy.resources`), `values/dcgm-exporter.yaml` (no `resources`).
- Problem: all four rely on chart defaults sized for generic clusters, not a single node also running 20+ GiB GPU model pods — the monitoring stack can OOM the node.
- Fix: set explicit requests/limits in each values file sized for mjolnir (e.g. prometheus 500m/2Gi → 2/8Gi; grafana 100m/512Mi; loki 200m/1Gi; alloy 100m/256Mi; dcgm 100m/512Mi) — tune against observed usage after a week.
- Sources: domain-monitoring F-P2-10.

**P2-29 — detect-secrets exclusion is broader than the sops file**
- `.pre-commit-config.yaml:33` (`exclude: (.*lock)|(secrets.yaml)|…`).
- Problem: `secrets.yaml` is an unanchored substring, so it matches **any** file ending in `secrets.yaml` anywhere in the repo (a future `k8s/apps/ai/secrets.yaml` with plaintext would be silently skipped).
- Fix: `exclude: (.*lock)|(nix/services/homelab/homelab-secrets\.yaml)|(nix/users/sops-secrets\.yaml)`.
- Sources: security-ops P2-1.

**P2-30 — mint script passes secrets as process argv (visible in `ps`)**
- `scripts/mint-litellm-key.sh:26,38` (master key in curl's argv; freshly minted key in yq's argv).
- Problem: both are visible to any local user via `ps` for the duration of the call.
- Fix: for curl, a 0600 config file (`header = "Authorization: Bearer …"`) + `curl -K "$cfg"` (with `trap` cleanup); for yq, pass the value via env (`KEY="$KEY" yq -i '.x = env(KEY)'`).
- Sources: security-ops P2-2.

**P2-31 — mint script failure path prints the full response body (which contains the new key) to stderr**
- `scripts/mint-litellm-key.sh:31-34`.
- Problem: if the gateway returns 200 with an unexpected shape (no `.key`/`.token`), the whole `RESP` — including the minted key — is dumped to stderr (and thus to shell history/CI logs).
- Fix: print only the error field with the key redacted (e.g. `jq -c '{error: (.message // .error // "unexpected response")}' | sed 's/"key":"[^"]*"/"key":"<redacted>"/'`).
- Sources: security-ops P2-3.

**P2-32 — `NAME` is unvalidated and interpolated into the JSON body**
- `scripts/mint-litellm-key.sh:12,27`.
- Problem: `NAME` flows into `{"key_alias":"$NAME",…}` unescaped (a name containing `"` breaks/injects the JSON) and becomes a Prometheus label (`api_key_alias`).
- Fix: `[[ "$NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || { echo "invalid key name" >&2; exit 1; }`.
- Sources: security-ops P2-4.

**P2-33 — master key and minted keys transit cleartext over LAN HTTP**
- `scripts/mint-litellm-key.sh:14` (`GATEWAY` defaults to `http://mjolnir:8000`) + runbook.
- Problem: every mint/revoke sends the master key in a cleartext `Authorization` header; acceptable on a trusted single-subnet homelab, but the weakest link in an otherwise sops-encrypted chain.
- Fix: document the trust assumption in the runbook (one line), or terminate TLS at a LAN proxy (traefik already runs) and point `LITELLM_GATEWAY` at it.
- Sources: security-ops P2-5.

**P2-34 — firewall opens node-exporter 9100 and kubelet 10250 to all sources**
- `nix/services/k3s.nix:302` (branch widens `allowedTCPPorts` from `[6443]` to `[6443 9100 10250]`).
- Problem: the intent is pod-CIDR→host reachability for Prometheus scrapes, but nixos `allowedTCPPorts` has no source restriction — the whole LAN can hit unauthenticated node-exporter (9100) and the kubelet API (10250; token-gated, but the surface is live).
- Fix: add an nftables rule accepting 9100/10250 only from the pod CIDR (e.g. `ip saddr 10.42.0.0/16`), keeping the INPUT chain closed to the rest of the LAN.
- Sources: security-ops P2-6; domain-manifests P2-9.

**P2-35 — kubelet-monitoring ServiceAccount token minted for 10 years**
- `nix/services/k3s.nix` (activation: `kubectl create token … --duration=87600h`).
- Problem: a long-lived bearer token stored in a Secret; a cluster compromise yields a 10-year-valid kubelet credential (the comment acknowledges the trade-off: no re-minting per deploy).
- Fix (optional): accept and document, or move to a projected token with a shorter TTL + cron/activation re-mint.
- Sources: security-ops P2-7.

**P2-36 — DCGM exporter pod runs as root with `SYS_ADMIN`**
- `k8s/apps/monitoring/values/dcgm-exporter.yaml:19-25`.
- Problem: documented as required for CDI driver access and the pod is in-cluster-only, so this is an exposure *depth* gap, not a reachability one: a compromised DCGM pod is root on the node.
- Fix: isolate it (dedicated namespace with an explicit PSS `baseline` label + networkPolicy) so the privileged exception is contained.
- Sources: security-ops P2-8.

**P2-37 — Grafana ingress is HTTP-only**
- `k8s/apps/monitoring/values/kube-prometheus-stack.yaml:143-147` (`grafana.mjolnir` via traefik, no certificate configured).
- Problem: the sops-managed admin password crosses the LAN in cleartext.
- Fix: add a self-signed (or internal CA) cert to the ingress (`tls:` block) — traefik is already the ingress class.
- Sources: security-ops P2-9.

**P2-38 — runbook "re-mint" guidance is misleading**
- `docs/runbook-mint-litellm-key.md` (Notes).
- Problem: "If the PV is wiped, re-mint the keys (the sops copies are the source of truth for re-handing them out)" conflates two things — the sops copy is a record for **re-handing keys to clients**, not a re-authentication mechanism; after a PV wipe the old keys are invalid in the fresh DB.
- Fix: reword: "After a PV wipe the minted keys are dead. Re-mint each alias (`just mint-key <name>`), which overwrites the sops entry, and re-hand the new keys to clients."
- Sources: security-ops P2-10.

**P2-39 — mint script leaves a plaintext window in the working tree**
- `scripts/mint-litellm-key.sh:39-40` (`cp /tmp/hl-plain.yaml "$F"` before `sops encrypt --in-place`).
- Problem: the sops file sits **plaintext on disk** between the `cp` and the encrypt; if the encrypt step fails (sops version drift, disk full), a plaintext secrets file is one accidental `git add` away from committing every secret.
- Fix: `sops encrypt "$T" > "$F.new" && mv "$F.new" "$F"` (atomic replace, no plaintext ever at `$F`).
- Sources: security-ops P2-11.

**P2-40 — runbook has no commit step after minting**
- `docs/runbook-mint-litellm-key.md` (Mint a key).
- Problem: the durable record is the sops file, but the runbook never says to `git commit` it after minting; an uncommitted mint is lost on `git checkout`/rebase.
- Fix: add "then `git commit nix/services/homelab/homelab-secrets.yaml`" to the mint section.
- Sources: security-ops P2-12.

**P2-41 — mint script: missing `jq` check, no curl timeout**
- `scripts/mint-litellm-key.sh` (misc; `jq` used at line 30, `curl` with no `--max-time`).
- Problem: `command -v sops` is checked but `jq` is not; a wedged gateway hangs the script forever.
- Fix: `command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 1; }` and `curl -fsS --max-time 30`.
- Sources: security-ops P2-13.

**P2-42 — sed-based secret injection in the activation script**
- `nix/services/k3s.nix:212-214` (`sed "s|__TELEGRAM_BOT_TOKEN__|$TG_TOKEN|"`).
- Problem: breaks if a value contains `|`, `&`, or `\`. Latent today (bot tokens are `[0-9A-Za-z_-]`, chat IDs numeric; the grafana password goes through `--from-literal`, not sed), but a footgun for the next secret.
- Fix: `envsubst` or a `yq` values merge.
- Sources: domain-manifests P2-4.

**P2-43 — kubelet-monitoring RBAC broader than needed; comment likely wrong**
- `k8s/manifests/kubelet-monitoring.yaml:20-24`.
- Problem: the comment asserts "k3s has no system:node-reader", but `system:node-reader` is standard k8s RBAC and k3s bootstraps it (verify with `k3s kubectl get clusterrole system:node-reader`); `system:kubelet-api-admin` grants **all verbs** on `nodes/proxy` (and metrics), broader than a scrape token needs. The k3s.nix:233 comment says "(system:node-reader)" while the manifest binds `system:kubelet-api-admin` — the two comments disagree.
- Fix: if node-reader exists, prefer it.
- Sources: domain-manifests P2-5.

**P2-44 — operator `rollout restart` on every activation**
- `nix/services/k3s.nix:287`.
- Problem: justified for fresh installs (operator only detects CRDs at startup), but on every subsequent deploy it needlessly restarts the kps operator (brief gap in Prometheus/Alertmanager/Grafana controller management).
- Fix: restart only when CRDs were newly created (check CRD existence before applying).
- Sources: domain-manifests P2-6.

**P2-45 — justfile `k8s-render`/`k8s-deploy` duplicate the activation render path; manual path skips secret refresh**
- `justfile:33-38` (re-implements the `F=(-f …)` loop from `aiChartRendered`, k3s.nix:27-34).
- Problem: two copies will drift if a values source is added to one only; `k8s-deploy` applies only the ai chart and does **not** refresh the `llm-api-key` secret, so a `podApiKey` change made via the manual path breaks monitoring auth until the next full `just deploy`. The recipe is also redundant — `just deploy mjolnir` ships the same chart.
- Fix: delete the recipes (ponytail), or one shared render script + add the secret refresh to `k8s-deploy` + document the divergence.
- Sources: domain-manifests P2-7; ponytail-audit #11.

**P2-46 — `local-pvs.yaml` nodeAffinity hardcodes hostname `mjolnir`**
- `k8s/manifests/local-pvs.yaml:27,51,79`.
- Problem: a node rename (or migration) orphans all three PVs (Retain keeps the data, but nothing can bind).
- Fix: select on a stable node label set in `k3s.nix` (e.g. a custom label like `storage=mjolnir`).
- Sources: domain-manifests P2-8.

**P2-47 — dual deploy paths (`copy $host` rsync vs `deploy $host` deploy-rs)**
- `justfile:18-19`.
- Problem: `copy $host` rsyncs the repo to `/etc/nixos` (impure, non-flake) while `deploy $host` uses deploy-rs against the flake; both work, but they can diverge (post-deploy steps, secret handling) and it's unclear which is canonical for mjolnir.
- Fix: mark one deprecated or document when each is used.
- Sources: domain-manifests P2-10.

**P2-48 — dead testpod machinery: throwaway `litellm-test` gateway template + `testPod` flag + `or .Values.gateway.testPod` gates + runbook sections**
- `k8s/apps/ai/templates/gateway-testpod.yaml` (83-line copy of the prod gateway deployment, git sees it as a 67% copy), `values.yaml:35-37` (`testPod: false` + comment), `templates/postgres-deployment.yaml` / `postgres-pvc.yaml` / `postgres-service.yaml` (`or .Values.gateway.testPod` in all three gates), `docs/runbook-mint-litellm-key.md` (test-pod sections).
- Problem: the testpod's stated purpose (validate key minting before cutover) is done, `testPod` is `false`, and prod is live — nothing replaces it.
- Fix: delete the template, the flag, the `or` conditions (gates reduce to `{{- if .Values.gateway.usePostgresKeys }}`, net 0), and the test-pod runbook sections (~100 lines).
- Sources: ponytail-audit #4; ponytail-review (gateway-testpod.yaml L1-83, values.yaml L35-37, postgres-* gates).

**P2-49 — `nixBinary`/`command` fork-binary mechanism + nix-store PV/PVC used by no live model**
- `k8s/apps/ai/templates/model-deployment.yaml:4-5` (the `$m.binary` branch set by no model — all 8 values files use `command`), `k8s/manifests/local-pvs.yaml` (nix-store PV/PVC).
- Problem: only the four dormant fork models use it; both live models use the image binary. Dead once the dormant values files are deleted (P2-50).
- Fix: drop the branch (the 8-line block becomes 5) and the nix-store PV/PVC (~44 lines).
- Sources: ponytail-audit #5; ponytail-review (model-deployment.yaml L4-5).

**P2-50 — six dormant model values files kept inert**
- `k8s/apps/ai/values/qwen3-8-27b.yaml`, `qwen3-8-27b-turboq.yaml`, `gemma-4-26b-a4b-longctx.yaml`, `qwen3-6-35b-iq4xs.yaml`, `qwen3-8-flash-next.yaml`, `qwen3-8-flash-next-256k.yaml` (all `enable: false`, comments say "kept inert" / "NOT adopted, kept inert").
- Problem: ~315 lines of dead config; the comments themselves say they're kept only in case a model is promoted.
- Fix: delete the files; re-add when a model is actually promoted.
- Sources: ponytail-audit #1.

**P2-51 — DCGM "GPU Utilization/VRAM" row duplicated in cluster-overview dashboard**
- `k8s/apps/monitoring/dashboards/cluster-overview.json`.
- Problem: llm-fleet already has the full 4-panel DCGM row; the cluster-overview copy is ~190 lines of duplication.
- Fix: drop the row from cluster-overview.
- Sources: ponytail-audit #2.

**P2-52 — `extraVolumes`/`extraMounts` escape hatch used by nobody live**
- `k8s/apps/ai/templates/model-deployment.yaml`, `k8s/apps/ai/values/qwen3-8-flash-next.yaml` (only dormant flash-next uses it; the `hostPath` branch is used by nobody).
- Problem: ~23 lines of dead flexibility.
- Fix: delete; dead once the dormant values files are deleted (P2-50).
- Sources: ponytail-audit #6.

**P2-53 — 7-line identical container hardening block repeated in 4 templates**
- `k8s/apps/ai/templates/{model-deployment,gateway-deployment,gateway-testpod,postgres-deployment}.yaml` (`allowPrivilegeEscalation`/`capabilities drop ALL`/`seccompProfile`).
- Problem: copy-pasted hardening block (3 copies after P2-48 lands).
- Fix: a helm named template (`{{ include "ai.harden" . }}`) shrinks it (~17 lines).
- Sources: ponytail-audit #7.

**P2-54 — cloud-model rate table maintained twice**
- `k8s/manifests/cloud-model-rates.yaml` (comment block) + `k8s/apps/monitoring/llama-metrics.md` (table).
- Problem: the same rate table is maintained in two places (~9 lines of duplication).
- Fix: keep one (the manifest, which is the source of truth).
- Sources: ponytail-audit #8.

**P2-55 — `usePostgresKeys` flag is always `true` since the cutover**
- `k8s/apps/ai/values.yaml`, `templates/{gateway-deployment,postgres-deployment,postgres-pvc,postgres-service}.yaml`.
- Problem: the flag and the `if`/`or` conditions around the gateway env and postgres resources are dead weight (~5 lines).
- Fix: drop the flag and the conditions.
- Sources: ponytail-audit #9.

**P2-56 — three identical 6-line chart renderers in k3s.nix**
- `nix/services/k3s.nix:74-99` (dcgm/loki/alloy renderers + the 3-line system.build block).
- Problem: three identical `runCommand` chart renderers.
- Fix: one `lib.genAttrs` over a {chart, values} attrset, ~11 lines.
- Sources: ponytail-review (k3s.nix L74-99).

**P2-57 — `chatTemplate.enable` global flag is always `true`**
- `k8s/apps/ai/values.yaml`, `k8s/apps/ai/templates/chat-template-configmap.yaml`.
- Problem: nobody toggles it; the per-model `chatTemplate: true` already gates the mount (~3 lines).
- Fix: delete the global flag.
- Sources: ponytail-audit #12.

**P2-58 — `postgresDataSize` set in values.yaml and re-defaulted to the same value in the template**
- `k8s/apps/ai/values.yaml`, `k8s/apps/ai/templates/postgres-pvc.yaml` (`| default "1Gi"`).
- Problem: the same default in two places (~1 line).
- Fix: keep one.
- Sources: ponytail-audit #13.

---

## Ponytail debt

Marker ledger from `ponytail-debt.md` (6 markers, 3 with no trigger). `no-trigger` = the marker names no upgrade path/trigger — highest rot risk.

| File:line | Marker | Ceiling | Upgrade trigger |
|---|---|---|---|
| `nix/hosts/mjolnir/_disko.nix:6` | disk device hardcoded to a single NVMe (`/dev/nvme0n1`) | single NVMe per system spec | verify via `lsblk` before install |
| `nix/hosts/mjolnir/default.nix:27` | boot entries capped at 3 systemd-boot generations (one ~180MB initrd per generation filled the 1GB `/boot` and broke deploys on 2026-09-18) | 3 boot generations on a 1GB `/boot` partition | **none named** `[no-trigger]` |
| `nix/hosts/mjolnir/default.nix:36` | Nix build cores capped at 8 | 8 cores (64 cores exhausts 96GB RAM during CUDA/Cython C++ compilation) | **none named** `[no-trigger]` |
| `nix/hosts/mjolnir/default.nix:39` | 32G swapfile added as a band-aid for compilation OOMs | 32G swapfile absorbing CUDA compilation memory spikes (nvcc cicc) | **none named** `[no-trigger]` |
| `nix/services/homelab/homelab.nix:23` | insecure package `pnpm-9.15.9` permitted for the karakeep build | build-time only | remove when nixpkgs bumps karakeep off `pnpm_9` |
| `nix/services/k3s.nix:17` | chart rendering hardcodes the single `ai` chart | one chart hardcoded | generalize to a chart list when a second app lands |

---

## Fix-ticket list

Ready-to-create tickets for every P0 and P1 finding.

| # | Ticket title | Scope (one line) | Files to touch |
|---|---|---|---|
| T1 (P0-1) | Delete the python log-exporter sidecar; use native llama.cpp gauges | Remove sidecar + log redirect + emptyDir + PodMonitor; point live-status panels at `llamacpp:predicted_tokens_seconds` / `llamacpp:prompt_tokens_seconds` (or, if kept, drop `readOnly: true` + `os.truncate`) | `k8s/apps/ai/templates/model-deployment.yaml`, `k8s/apps/ai/templates/log-exporter-configmap.yaml`, `k8s/apps/monitoring/values/kube-prometheus-stack.yaml`, `k8s/apps/monitoring/dashboards/llm-fleet.json` |
| T2 (P0-2) | Fix llm-fleet throughput panels 128/129 (nonexistent metrics + label) | Replace `llamacpp_live_*_tps{model=…}` with `sum by (job) (llamacpp:predicted/prompt_tokens_seconds{job=~"$model"})` | `k8s/apps/monitoring/dashboards/llm-fleet.json` |
| T3 (P1-1) | Authenticate the gateway `/metrics` endpoint | `require_auth_for_metrics_endpoint: true`, mint a dedicated metrics key, point the ai-fleet monitor's `bearerTokenFile` at it | `k8s/apps/ai/templates/gateway-configmap.yaml`, `nix/services/homelab/homelab-secrets.yaml`, `k8s/apps/monitoring/values/kube-prometheus-stack.yaml`, `scripts/mint-litellm-key.sh` (via `just mint-key metrics`) |
| T4 (P1-2) | Make `mint-litellm-key.sh` idempotent | Check-for-existing (`GET /key/info`) before create; print sops copy and exit 0 on re-run | `scripts/mint-litellm-key.sh` |
| T5 (P1-3) | Stop dumping decrypted secrets to a fixed world-readable /tmp file | `umask 077` + `mktemp` + `trap 'rm -f' EXIT` (match the k3s.nix activation pattern) | `scripts/mint-litellm-key.sh` |
| T6 (P1-4) | Add missing runbook sections (age keys, sops rotation, re-apply) | "Secrets & age keys" section: key locations/backup, `sops updatekeys` procedure, `just deploy mjolnir` re-apply note — acute because this branch rotates the mjolnir age recipient | `docs/runbook-mint-litellm-key.md` |
| T7 (P1-5) | Exit non-zero when the aiChart activation retry loop fails | `exit 1` after the 60 s loop so deploy-rs reports the failure | `nix/services/k3s.nix` |
| T8 (P1-6) | Derive `LLM_KEY` from values and assert non-empty | Replace grep/sed over rendered YAML with `yq -r '.gateway.podApiKey'` + `[ -n "$LLM_KEY" ] \|\| exit 1` | `nix/services/k3s.nix` |
| T9 (P1-7) | Prune removed resources on activation (or adopt Helm releases) | `kubectl apply --prune -l <label>` with a common label, or `helm upgrade --install`; fix the testpod "prunes it" comment | `nix/services/k3s.nix`, `k8s/apps/ai/templates/gateway-testpod.yaml` |
| T10 (P1-8) | Add container securityContext to the log-exporter sidecar | Copy the `llama-server` block (`allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`) — moot if T1 deletes the sidecar | `k8s/apps/ai/templates/model-deployment.yaml` |
| T11 (P1-9) | Digest-pin the enabled images | `@sha256:` digests for gemma-4-26b-a4b, swift-qwen3-8-27b, litellm v1.102.1; exact tag for postgres | `k8s/apps/ai/values/gemma-4-26b-a4b.yaml`, `k8s/apps/ai/values/swift-qwen3-8-27b.yaml`, `k8s/apps/ai/values.yaml` |
| T12 (P1-10) | Make the startupProbe budget per-model | Move `periodSeconds`/`failureThreshold` into per-model values with chart defaults; larger budget for flash-next | `k8s/apps/ai/templates/model-deployment.yaml`, `k8s/apps/ai/values.yaml`, `k8s/apps/ai/values/qwen3-8-flash-next.yaml`, `k8s/apps/ai/values/qwen3-8-flash-next-256k.yaml` |
| T13 (P1-11) | Resolve the missing `llama-metrics.yaml` artifact | Create the dedicated ServiceMonitor in the ai chart (and drop the model-pod portion of kps `ai-fleet`), or confirm the kps-values design and update ticket scope | `k8s/apps/ai/templates/llama-metrics.yaml` (new), `k8s/apps/monitoring/values/kube-prometheus-stack.yaml` |
| T14 (P1-12) | Move per-token cost math into a recording rule | Add `ai:litellm:cost:increase1h` recording rule; dashboards read the result (at minimum de-duplicate the inlined expression) | `k8s/manifests/cloud-model-rates.yaml`, `k8s/apps/monitoring/dashboards/llm-overview.json` |
| T15 (P1-13) | Pin the DCGM exporter to GPU nodes explicitly | Add `nodeSelector: {nvidia.com/gpu.present: "true"}` (verify label against `kubectl get nodes --show-labels`) | `k8s/apps/monitoring/values/dcgm-exporter.yaml` |
| T16 (P1-14) | Fix llm-fleet MTP acceptance panel to use rate()/rate() | Replace the raw-counter ratio with `rate(…accepted…[5m]) / rate(…draft…[5m])` | `k8s/apps/monitoring/dashboards/llm-fleet.json` |
| T17 (P1-15) | Fix percentunit-on-cores in 3 cluster-overview CPU panels | Divide by `machine_cpu_cores` (keep `percentunit`) or switch unit to `short` + "(cores)" rename | `k8s/apps/monitoring/dashboards/cluster-overview.json` |

---

## Summary

### Counts by priority (deduplicated)

| Priority | Count |
|---|---|
| P0 | 2 |
| P1 | 15 |
| P2 | 58 |
| **Total** | **75** |

Raw input counts (pre-dedup): 3 P0, 16 P1, 53 P2 (72 domain-pass findings) + 20 ponytail items = 92 → 75 after 17 items merged (11 merged groups: 8 spanning multiple passes, 3 within a single pass — all listed in the header table).

### Counts by pass (raw, pre-dedup)

| Pass | P0 | P1 | P2 | Total |
|---|---|---|---|---|
| research.md (brief, context only) | — | — | — | 0 |
| ponytail-review.md | — | — | 7 | 7 |
| ponytail-audit.md | — | — | 13 | 13 |
| ponytail-debt.md (ledger) | — | — | — | 0 (6 markers) |
| domain-chart.md | 1 | 3 | 13 | 17 |
| domain-dashboards.md | 2 | 3 | 9 | 14 |
| domain-monitoring.md | 0 | 3 | 10 | 13 |
| security-ops.md | 0 | 4 | 14 | 18 |
| domain-manifests.md | 0 | 3 | 7 | 10 |
| **Total** | **3** | **16** | **53** | **92** |

### Top-5 highest-impact findings

1. **P0-1 — log-exporter sidecar** (domain-chart P0-1 + ponytail-audit #3): the tail thread dies permanently after ~100 MiB of model log (read-only mount + truncating rotation), silently freezing the live decode/prefill gauges and stopping Loki log shipping — then the unrotated log fills the 200 Mi emptyDir and the model's own log writes fail with ENOSPC. The ponytail pass additionally shows the entire sidecar is unnecessary: llama.cpp exposes the same rates natively.
2. **P0-2 — llm-fleet headline throughput panels render empty** (domain-dashboards P0-1/P0-2/P1-1): both "Decode tokens/s" and "Prompt tokens/s" panels query metrics that do not exist and filter on a `model` label the pods never emit — the dashboard's two most prominent panels show nothing.
3. **P1-1 — gateway `/metrics` unauthenticated on a LAN-reachable hostPort** (security-ops P1-1): `http://mjolnir:8000/metrics` serves spend/token/latency data to anyone on the LAN with no credential.
4. **P1-5/P1-6 — activation script swallows failures and silently mints an empty monitoring key** (domain-manifests P1-1/P1-2): deploy-rs reports success when the chart apply never happened, and a chart change to the `--api-key` arg shape yields an empty `llm-api-key` Secret with no deploy-time error — the two failures that would make a broken deploy look healthy.
5. **P1-3 + P1-4 — mint script secret hygiene + runbook gaps** (security-ops P1-3/P1-4): the entire decrypted sops file is dumped to a world-readable `/tmp` path that is never deleted, and the runbook omits age-key location/backup — acute because this branch rotates the mjolnir age recipient, so a missing key on the node bricks every secret-fed component with no documented recovery.

### Overall assessment

The branch is well above average for a homelab fleet and is structurally sound: the secret-handling backbone is solid (sops/age fully encrypted, single source of truth, sops-nix → K8s Secrets → `secretKeyRef` with no plaintext anywhere in the diff — verified by full tree greps), the PV/PVC/chart wiring, RuntimeClass, kubelet token, and activation ordering all line up, the chart's single-node k3s fit (replicas 1, Recreate strategies with documented GPU/hostPort rationale, static Retain PVs, PSS-restricted containers) is right, and every LiteLLM/llama.cpp/DCGM metric name in the scrape configs, rules, and dashboards matches the live-verified catalog.

The real defects concentrate in four places: (1) the log-exporter sidecar — broken by a read-only-mount bug and unnecessary in principle (P0-1); (2) the llm-fleet dashboard's headline panels, which were written against a nonexistent metric/label pair (P0-2, P1-14, P1-15); (3) the activation script in `k3s.nix`, whose swallowed failures, unguarded key extraction, and apply-without-prune pattern make broken deploys look successful and leak resources when values shrink (P1-5/6/7); and (4) the mint script + runbook, which leak decrypted secrets to `/tmp`/argv/stderr and omit the age-key/rotation/re-apply documentation the brief mandates (P1-2/3/4).

The ponytail passes add a consistent over-engineering theme: ~875 lines of dead code (dormant model values, the finished testpod, unused escape hatches, duplicated dashboard rows) that should be deleted before merge. The 47 P2s are hygiene — resources/limits, schema/helpers, probe tuning, selector scoping, comment accuracy, and LAN exposure tightening — none of which break current functionality.

**Recommendation:** fix the 2 P0s and the 15 P1s (tickets T1–T17) before merge; batch the P2s into follow-up tickets; delete the ponytail dead code as part of the P0-1/P1-7 work where they overlap.
