# Domain Review: ai Helm chart + values

**Ticket:** mestruble-3x7.1 — "[review] Domain review: ai Helm chart + values"
**Date:** 2026-10-04
**Scope:** `k8s/apps/ai/` — Chart.yaml, values.yaml, all 11 templates, all 8 `values/*.yaml`.
**Method:** reviewed against the best-practices brief (`docs/review/feat-observability/research.md`, sections 1, 2, 5, 6) and the helm / k8s-workloads / k8s-networking / k8s-storage / k3s skills. Deployment context: rendered with `helm template` (9 merged `-f` values files) and applied with plain `kubectl apply` (no `--prune`) by the `aiChart` activation script in `nix/services/k3s.nix` — so release-level Helm semantics (NOTES.txt, `helm uninstall` PVC deletion, release secrets) do not apply, and apply-time pruning does not happen.

## Findings

### P0

**P0-1 — log-exporter rotates a log it mounts read-only; tail thread dies after 100 MiB**
- `templates/model-deployment.yaml:174` (exporter `log` volumeMount `readOnly: true`) + `templates/log-exporter-configmap.yaml:50` (`with open(LOG_FILE, "w"): pass` rotation).
- What's wrong: the exporter truncates `llama.log` once it exceeds `ROTATE_BYTES` (100 MiB), but its mount of the shared `log` emptyDir is read-only. `open(LOG_FILE, "w")` raises `PermissionError` (EROFS), which is not caught (only `FileNotFoundError` is, `log-exporter-configmap.yaml:66`), so the daemon tail thread dies permanently. After ~100 MiB of model log: (a) the live decode/prefill gauges freeze at their last value (metrics server keeps serving stale state), and (b) the stdout echo to Alloy → Loki stops. Worse, with rotation dead the log then grows into the emptyDir's `sizeLimit: 200Mi` (`model-deployment.yaml:188`), after which the model's `>> /var/log/llama.log` writes fail with ENOSPC.
- Fix: drop `readOnly: true` from the exporter's `log` volumeMount (brief §2.5's "main writes, exporter tails" pattern does not require the tailer's mount to be read-only — it's the same emptyDir). Verify by forcing a >100 MiB log and confirming the gauges keep moving.

### P1

**P1-1 — log-exporter sidecar has no container securityContext → pod fails PSS restricted**
- `templates/model-deployment.yaml:151-179` (the `log-exporter` container has no `securityContext` block at all).
- What's wrong: the pod-level `runAsUser: 1000` covers non-root, but PSS "restricted" (brief §2.3) additionally requires per-container `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, and `seccompProfile.type: RuntimeDefault`. Every other container in the chart sets these; the sidecar doesn't, so the whole pod is non-compliant.
- Fix: add the same container-level block the `llama-server` container uses (lines 70-78) to `log-exporter`.

**P1-2 — enabled images are tag-pinned, not digest-pinned**
- `values/gemma-4-26b-a4b.yaml:4` and `values/swift-qwen3-8-27b.yaml:7` (`ghcr.io/ggml-org/llama.cpp:server-cuda12-b11151` — the two *enabled* models), `values.yaml:25` (`ghcr.io/berriai/litellm:v1.102.1`), `values.yaml:28` (`postgres:16-alpine` — a floating minor tag).
- What's wrong: brief §1.5 requires digest pinning for reproducible deploys, and the chart's own header (`values.yaml:5`) documents "image: digest-pinned" — 4 of 8 model entries comply, the two that are actually running don't. `postgres:16-alpine` can silently change minor version on re-pull.
- Fix: pin all four with `@sha256:` digests (`docker buildx imagetools inspect <ref>`); at minimum pin postgres to an exact tag (e.g. `16.4-alpine3.20`).

**P1-3 — startupProbe budget is hard-coded for all models**
- `templates/model-deployment.yaml:107-112` (`failureThreshold: 30` × `periodSeconds: 10` = 300 s, fixed in the template).
- What's wrong: brief §2.1 requires a startup budget sized to the slowest load. The comment (`model-deployment.yaml:104`) sizes it for a "20GB load", but the flash-next entries (`values/qwen3-8-flash-next.yaml`, `values/qwen3-8-flash-next-256k.yaml` — 125B-class, 8 Gi request / 80 Gi limit, cold experts on CPU) can plausibly exceed 5 min to load; a failed startupProbe kills the container mid-load → CrashLoop. Because the budget lives in the template, no per-model values file can extend it.
- Fix: move startupProbe params into per-model values (e.g. `startupProbe: {periodSeconds, failureThreshold}` with chart defaults) and give flash-next a larger budget.

### P2

**P2-1 — no CPU requests/limits on any container; log-exporter has no resources at all**
- `templates/model-deployment.yaml:148-152` (memory only), `templates/gateway-deployment.yaml:81-84`, `templates/postgres-deployment.yaml:59-62`, `templates/model-deployment.yaml:151-179` (exporter: none).
- What's wrong: brief §2.2 says set both requests and limits on every container. Memory is set everywhere; CPU is nowhere, so the exporter is BestEffort and the rest Burstable.
- Fix: add CPU requests (e.g. 500m gateway, 250m postgres, 100m exporter). CPU *limits* are legitimately skippable for inference workloads (throttling hurts t/s) — if skipped, say so in a comment.

**P2-2 — no `values.schema.json`**
- Chart root.
- What's wrong: brief §1.1 — a schema makes typos in per-model keys (`memoryReqest`, `chatTemplte`) fail fast at render time; today they render `null` and the failure surfaces later as a cryptic `kubectl apply` validation error.
- Fix: add `values.schema.json` covering `models.*` (`enable`, `image`, `gpu`, `port`, `modelName`, `memoryRequest`, `memoryLimit`, `args`, `nixBinary`, `command`, `chatTemplate`, `extraVolumes`, `extraMounts`) and the `gateway.*` keys.

**P2-3 — no `_helpers.tpl`; non-standard label set**
- All templates (labels inlined per resource).
- What's wrong: brief §1.3 — reusable logic (labels, image ref) should live in named templates; the chart only emits `app: <name>` + `app.kubernetes.io/part-of: ai`, missing `app.kubernetes.io/name` and `app.kubernetes.io/managed-by` (k8s-workloads label conventions).
- Fix: add `_helpers.tpl` with `ai.labels`/`ai.selectorLabels` and the standard labels.

**P2-4 — pod API key in values, in container args, and grep-extracted by the activation script**
- `values.yaml:27` (`podApiKey: foo`), `templates/model-deployment.yaml:89-90` (`--api-key` as a container arg → visible in the pod spec, etcd, and `kubectl get deploy -o yaml`), `templates/gateway-configmap.yaml:17` (plain in the ConfigMap), plus the `grep -A1 '"--api-key"'` extraction in `nix/services/k3s.nix` that builds the `llm-api-key` Secret for monitoring.
- What's wrong: brief §6.3 — sensitive values belong in Secrets referenced via `secretKeyRef`. The current value is a documented LAN-only placeholder, so risk is low, but the pattern (key in args + scraping rendered YAML for it) is fragile and breaks if the arg format changes.
- Fix: move the key into the sops-managed `litellm-keys` Secret, pass it via `secretKeyRef` (env), and point the monitoring scrape at the same Secret.

**P2-5 — gateway `api_base` hard-codes the `default` namespace**
- `templates/gateway-configmap.yaml:16` (`http://{{ $name }}.default.svc.cluster.local:{{ $m.port }}/v1`).
- What's wrong: the chart has no namespace value and is pinned to `default` (k3s skill: don't run workloads in `default`); moving the fleet to a dedicated namespace requires editing the template.
- Fix: add a `namespace` value (default `default`) and interpolate it.

**P2-6 — no `timeoutSeconds` on any probe**
- `templates/model-deployment.yaml:107-117`, `templates/gateway-deployment.yaml:75-80`, `templates/postgres-deployment.yaml:53-57` (all default to 1 s).
- What's wrong: llama-server's `/health` can be slow under heavy load; a 1 s timeout causes spurious readiness flaps → gateway 502s mid-burst.
- Fix: `timeoutSeconds: 5` on the model probes (3 is fine for gateway/postgres).

**P2-7 — model `/dev/shm` is a 32 Gi tmpfs**
- `templates/model-deployment.yaml:214-216` (`medium: Memory`, `sizeLimit: 32Gi`).
- What's wrong: tmpfs counts against node RAM; llama.cpp's default shared-memory use is small, so a 32 Gi cap per model pod is a large single-node exposure if several models run.
- Fix: size to observed usage (2-4 Gi) or make it a per-model value.

**P2-8 — hard-coded ports not overridable via values**
- `templates/gateway-testpod.yaml:45` (hostPort 8001), `templates/model-deployment.yaml:167,170` (exporter port 9399 in both env and containerPort).
- What's wrong: brief §1.1 — every overridable knob belongs in values; these are baked into templates.
- Fix: `gateway.testPodPort` and `logExporter.port` values.

**P2-9 — gateway has no livenessProbe and no terminationGracePeriodSeconds**
- `templates/gateway-deployment.yaml` (readiness only; default 30 s grace).
- What's wrong: a wedged LiteLLM is never restarted, and 30 s may cut off in-flight generations (the model pods deliberately set 120 s for exactly this reason, `model-deployment.yaml:44-46`).
- Fix: liveness on `/health/liveliness` + `terminationGracePeriodSeconds: 120`. (The model pods' *deliberate* omission of liveness is documented at `model-deployment.yaml:105` and is acceptable — brief §2.1's "liveness looser than readiness" is satisfied by its absence.)

**P2-10 — postgres container lacks `readOnlyRootFilesystem`**
- `templates/postgres-deployment.yaml:34-39`.
- What's wrong: not a PSS-restricted violation (baseline is met), but brief §1.7 wants it as a chart default. The image needs `/var/run/postgresql` and `/tmp`.
- Fix: add `readOnlyRootFilesystem: true` plus small `emptyDir`s for `/var/run/postgresql` and `/tmp`.

**P2-11 — exporter HTTP server is single-threaded**
- `templates/log-exporter-configmap.yaml` (`HTTPServer(...).serve_forever()`).
- What's wrong: one slow scrape blocks all subsequent scrapes (Prometheus scrape timeout churn).
- Fix: `ThreadingHTTPServer`.

**P2-12 — comment claims this k3s build rejects pod-level `readOnlyRootFilesystem`**
- `templates/model-deployment.yaml:56-60`, `templates/gateway-deployment.yaml:38-40`.
- What's wrong: `PodSecurityContext.readOnlyRootFilesystem` has been standard since k8s 1.14; "unknown-field rejection" on k3s 1.35 is implausible. If client-side apply is pruning the field, the container-level placement is silently masking it.
- Fix: verify with `kubectl get pod -o yaml` on the cluster; if the field survives at pod level, move it up (it's the cleaner, brief-aligned location).

**P2-13 — testpod comment claims `kubectl apply` prunes it**
- `templates/gateway-testpod.yaml:5` ("helm/kubectl apply prunes it").
- What's wrong: the activation script runs plain `kubectl apply` without `--prune` (`nix/services/k3s.nix`), so setting `gateway.testPod: false` leaves the `litellm-test` Deployment (and hostPort 8001) in the cluster until manually deleted.
- Fix: correct the comment to "delete manually" (or add `--prune` with a label selector to the activation script).

## Per-file verdicts

| File | Verdict |
|---|---|
| `Chart.yaml` | OK — v2, semver `version` + `appVersion`, sensible description. |
| `values.yaml` | OK as structure (single source of truth, documented knobs); findings P1-2 (image tags), P2-4 (podApiKey). |
| `templates/model-deployment.yaml` | Core findings: P0-1, P1-1, P1-3, P2-1, P2-6, P2-7, P2-8, P2-12. Recreate strategy, 120 s grace, `automountServiceAccountToken: false`, and the probe semantics (startup+readiness, no liveness, documented) are all sound. |
| `templates/model-service.yaml` | OK — named `http` port for the ServiceMonitor, selector matches pod labels. |
| `templates/gateway-deployment.yaml` | Findings P2-1, P2-6, P2-9, P2-12. Recreate-for-hostPort rationale is correct. |
| `templates/gateway-service.yaml` | OK — ClusterIP, named port. |
| `templates/gateway-configmap.yaml` | Findings P2-4, P2-5. `require_auth_for_metrics_endpoint: false` is acceptable: ClusterIP-only, no ingress (brief residual-gap check passes). |
| `templates/gateway-testpod.yaml` | Findings P2-8, P2-13. Security context otherwise matches prod. |
| `templates/log-exporter-configmap.yaml` | P0-1 (rotation vs read-only mount), P2-11. Shared-emptyDir + own-metrics-port sidecar pattern matches brief §2.5; stdlib-only is a plus. |
| `templates/postgres-deployment.yaml` | Findings P2-1, P2-6, P2-10. Password via `secretKeyRef` (brief §6.3) and Recreate-for-RWO are correct. |
| `templates/postgres-pvc.yaml` | OK — explicit `storageClassName`, sized from values, binds the static Retain PV in `k8s/manifests/local-pvs.yaml` (brief §2.4). |
| `templates/postgres-service.yaml` | OK. |
| `templates/chat-template-configmap.yaml` | OK — `.Files.Get` inserts the jinja verbatim (no re-templating), `indent 4` correct. |
| `values/gemma-4-26b-a4b.yaml` | P1-2 (tag-only image on an enabled model). |
| `values/gemma-4-26b-a4b-longctx.yaml` | OK — digest-pinned, disabled. |
| `values/qwen3-6-35b-iq4xs.yaml` | OK — digest-pinned, disabled. |
| `values/qwen3-8-27b.yaml` | OK — exact `nvidia/cuda` tag (digest would be better, covered by P1-2's fix pattern), disabled. |
| `values/qwen3-8-27b-turboq.yaml` | OK — same as above, disabled. |
| `values/qwen3-8-flash-next.yaml` | P1-3 (startup-budget risk). 8 Gi/80 Gi request/limit split for CPU-resident cold experts is a deliberate, documented choice. |
| `values/qwen3-8-flash-next-256k.yaml` | P1-3 (same), disabled. |
| `values/swift-qwen3-8-27b.yaml` | P1-2 (tag-only image on an enabled model). |

## Summary

The chart is well above average for a homelab fleet: single-node k3s fit is right (replicas 1, no anti-affinity, Recreate strategies with documented GPU/hostPort rationale, static Retain PVs for PSS-restricted storage), the probe semantics for model loading are thoughtfully designed, secrets are wired via `secretKeyRef` from a sops-fed Secret, and the log-exporter follows the brief's shared-emptyDir/own-port sidecar pattern. The one real defect is P0-1: the exporter truncates a log it mounts read-only, so the tail thread dies after 100 MiB and both the live-rate metrics and Loki log shipping silently stop. The P1s are reproducibility and robustness gaps against the brief — tag-pinned images on the two running models plus gateway/postgres, a hard-coded 5-minute startup budget that can't be extended for the 125B-class flash-next models, and a sidecar missing the container securityContext that makes every other container PSS-restricted-compliant. The P2s are hygiene: CPU resources, a values schema, helpers/labels, the placeholder key's arg-based plumbing, hard-coded namespace/ports, probe timeouts, and two comments that don't match how the activation script actually applies the chart.
