# Domain Review: PrometheusRule + monitoring values + llama-metrics

**Ticket:** mestruble-3x7.7 — "[review] Domain review: PrometheusRule + monitoring values + llama-metrics"
**Date:** 2026-10-04
**Repo/branch:** /Users/mestruble/Software/nix-config @ `feat/observability`
**Scope (every file reviewed):**
- `k8s/apps/monitoring/prometheus-rule.yaml` — **does not exist** (see F-P2-3); the branch's only PrometheusRule is `k8s/manifests/cloud-model-rates.yaml` (reviewed)
- `k8s/manifests/cloud-model-rates.yaml`
- `k8s/apps/monitoring/values/kube-prometheus-stack.yaml` (chart 91.7.0)
- `k8s/apps/monitoring/values/loki.yaml` (grafana-community/loki 18.13.5)
- `k8s/apps/monitoring/values/alloy.yaml` (grafana/alloy 1.13.0)
- `k8s/apps/monitoring/values/dcgm-exporter.yaml` (NVIDIA dcgm-exporter 4.8.4)
- `k8s/apps/ai/templates/llama-metrics.yaml` — **does not exist** (see F-P1-1)
- `k8s/apps/monitoring/llama-metrics.md` (live-captured metric catalog, ground truth)

**Method:** file-by-file review against `docs/review/feat-observability/research.md` §3 (Prometheus rules, LIVE-VERIFIED LiteLLM metric names in §3.7) and §5 (stack values), plus the promql/grafana/k3s skills. Cross-checked scrape wiring end-to-end (ServiceMonitor/PodMonitor port names vs. actual Service/Pod ports in `k8s/apps/ai/templates/`), the activation-script apply order in `nix/services/k3s.nix`, and dashboard queries in `k8s/apps/monitoring/dashboards/*.json` for metric-name verification. Pinned chart versions taken from `nix/services/k3s.nix` (kps 91.7.0, loki 18.13.5, alloy 1.13.0, dcgm 4.8.4). Chart `.tgz` files were not available in the local nix store, so value keys were checked against chart knowledge + the research brief's live-verified sections (residual risk noted at the end).

---

## Findings

### P1

**F-P1-1 — `k8s/apps/ai/templates/llama-metrics.yaml` does not exist**
- What's wrong: the ticket lists this file in scope, but it is absent from the branch and has never been committed (`git log --all -- k8s/apps/ai/templates/llama-metrics.yaml` is empty). The llama.cpp metrics wiring that such a file would contain is instead embedded in `k8s/apps/monitoring/values/kube-prometheus-stack.yaml` (`additionalServiceMonitors: ai-fleet`, `additionalPodMonitors: llm-log-exporter`), so functionality is covered — but the expected artifact is missing and the wiring is split across files.
- Fix: either (a) create `k8s/apps/ai/templates/llama-metrics.yaml` as a dedicated ServiceMonitor for the llama.cpp model pods (`/metrics`, 30s, `bearerTokenFile` for the pod API key) rendered by the ai chart, and drop the model-pod portion of the kps `ai-fleet` monitor; or (b) confirm the consolidated-in-kps-values design is intentional and update the ticket scope. No functional breakage today.

**F-P1-2 — Per-token cost is not a recording rule; the math is inlined and duplicated in the dashboard**
- File: `k8s/manifests/cloud-model-rates.yaml` (the branch's only PrometheusRule) + `k8s/apps/monitoring/dashboards/llm-overview.json` (context)
- What's wrong: research §3.4 requires "Compute per-token cost as a recording rule: `cost = tokens × unit_price` … so dashboards just read the result". The branch records only the price constants (`cloud_model_rates`); the cost math is inlined in `llm-overview.json` and the identical ~300-char expression is duplicated verbatim in two panels ("Est. cloud cost avoided (range)" and "Net savings (range)"). Any formula change (e.g. a new token_type) must be made in two places.
- Metric-name check (the part that passes): every LiteLLM metric used in the cost math matches §3.7 with the `_total` counter suffix — `litellm_input_tokens_metric_total`, `litellm_input_cached_tokens_metric_total`, `litellm_output_tokens_metric_total`; `increase()` is the correct choice for "how many in the window" (§3.5); cached tokens are correctly subtracted from input (cached ⊂ input, per llama-metrics.md). No `litellm_requests_metric` (deprecated) anywhere.
- Fix: add a recording rule to the existing rule file, e.g.
  ```yaml
  - record: ai:litellm:cost:increase1h
    expr: sum by (profile) (
      (increase(litellm_input_tokens_metric_total[1h]) - increase(litellm_input_cached_tokens_metric_total[1h]))/1e6 * cloud_model_rates{token_type="input"}
      + increase(litellm_input_cached_tokens_metric_total[1h])/1e6 * cloud_model_rates{token_type="cached"}
      + increase(litellm_output_tokens_metric_total[1h])/1e6 * cloud_model_rates{token_type="output"}
    )
  ```
  (vector matching is 1-to-many via the `profile` label on `cloud_model_rates`; the dashboard then reads `ai:litellm:cost:increase1h{profile="$rate_profile"}` for fixed-window views). If the range-dependent `$__range` cost panels must stay, at minimum extract the shared expression into one place (single panel + `Net savings` referencing it, or a dashboard variable) so the formula exists once.

**F-P1-3 — DCGM values: no explicit GPU scheduling (nodeSelector/affinity)**
- File: `k8s/apps/monitoring/values/dcgm-exporter.yaml` (whole file)
- What's wrong: research §5.5 (LIVE-VERIFIED) says the chart's values include `nodeSelector`, `tolerations`, `affinity` (e.g. `nvidia-gpu` Exists) and the exporter should be pinned to GPU nodes. The values file sets none of them, so GPU-node scheduling relies entirely on the chart's default `nodeSelector` (the NVIDIA chart defaults to `nvidia.com/gpu.present: "true"`). The values file's own comment ("Verified at deploy that both TITANs report") implies the node carries that label today, but the intent is invisible in the values and will silently break if the chart default changes or a second, non-GPU node is added (exporter scheduled off-GPU → no metrics, no alert).
- Fix: add explicitly to `k8s/apps/monitoring/values/dcgm-exporter.yaml`:
  ```yaml
  # Pin the exporter to GPU nodes (the node carries nvidia.com/gpu.present
  # from the k3s GPU setup; verified at deploy).
  nodeSelector:
    nvidia.com/gpu.present: "true"
  ```
  (or `affinity` with `nvidia.com/gpu` Exists if the label scheme differs — verify against `kubectl get nodes --show-labels` on mjolnir).

### P2

**F-P2-1 — Recording rule name violates the namespace-prefix / `:` convention**
- File: `k8s/manifests/cloud-model-rates.yaml:32` (all 15 rules, `record: cloud_model_rates`)
- What's wrong: research §3.3: "Name recording rules with a namespace prefix and `:` separators (e.g., `ai:litellm:cost:rate5m`)". `cloud_model_rates` has neither a namespace prefix nor `:` separators.
- Fix: rename to `ai:cloud_model:rates` (keep the shared-name/different-label-sets pattern — it is legal and documented in the file header). Requires a coordinated update of the two references: `k8s/apps/monitoring/dashboards/llm-overview.json` (queries + `$rate_profile` usage) and the "Cloud model rates" section of `k8s/apps/monitoring/llama-metrics.md`.

**F-P2-2 — Hardcoded cloud prices will go stale with no runbook**
- File: `k8s/manifests/cloud-model-rates.yaml:9` ("Rates as of 2026-07")
- What's wrong: prices are baked into the rule as of 2026-07; provider price changes silently skew the "Est. cloud cost avoided" panel. Research §6.5 asks for runbook hygiene (exact commands to re-apply after a change).
- Fix: extend the file header comment with the update procedure: edit the `vector(...)` constants, `k3s kubectl apply -f k8s/manifests/cloud-model-rates.yaml` (or `just deploy mjolnir`, which re-applies it in the activation script), and update the table in `llama-metrics.md`.

**F-P2-3 — Scope note: `k8s/apps/monitoring/prometheus-rule.yaml` does not exist**
- What's wrong: the ticket names this file, but the branch contains exactly one PrometheusRule, `k8s/manifests/cloud-model-rates.yaml` (applied in the `k3s.nix` activation script). No other `kind: PrometheusRule` exists in the repo (grep-verified).
- Fix: none functionally — the ticket's filename was a guess; the real file was reviewed above. Update the ticket scope to point at `k8s/manifests/cloud-model-rates.yaml`.

**F-P2-4 — kps values header comment is stale (build-time vs activation-time)**
- File: `k8s/apps/monitoring/values/kube-prometheus-stack.yaml:3-4`
- What's wrong: header says "RENDERED AT BUILD TIME … (see nix/services/k3s.nix -> kpsValuesRendered)", but `k3s.nix` renders kps in the **activation script** (the comment block at k3s.nix:44-50 says exactly this), and no `kpsValuesRendered` variable exists.
- Fix: rewrite the header to "RENDERED AT ACTIVATION TIME: `__TELEGRAM_BOT_TOKEN__` / `__TELEGRAM_CHAT_ID__` are substituted from sops in the activation script (nix/services/k3s.nix -> system.activationScripts.aiChart). Do not commit real tokens."

**F-P2-5 — Stale comment: "DCGM is deployed in a later ticket"**
- File: `k8s/apps/monitoring/values/kube-prometheus-stack.yaml:71`
- What's wrong: DCGM is deployed in this branch (`dcgmChartRendered` is applied in the same activation script, k3s.nix). The comment ("the monitor is harmless (no targets) until the dcgm-exporter Service exists") is no longer true.
- Fix: replace with "DCGM exporter is deployed in the same activation script; this monitor picks up its Service (`app.kubernetes.io/name: dcgm-exporter`, port `metrics`)."

**F-P2-6 — `ai-fleet` ServiceMonitor selector is broader than intended (matches the postgres Service)**
- File: `k8s/apps/monitoring/values/kube-prometheus-stack.yaml:95-100`
- What's wrong: the selector `app.kubernetes.io/part-of: ai` matches every ai Service, including `postgres` (k8s/apps/ai/templates/postgres-service.yaml), whose single port (5432) is **unnamed** — so the `port: http` endpoint cannot resolve for it. prometheus-operator silently skips it (no target, no down alert), so it's harmless today, but the selector advertises coverage it doesn't have and will surprise anyone adding a port-named Service later.
- Fix: narrow the selector to the scraped Services, e.g. add `app.kubernetes.io/component: llm` to the model + gateway Services (model-service.yaml, gateway-service.yaml) and select on `matchLabels: {app.kubernetes.io/part-of: ai, app.kubernetes.io/component: llm}`.

**F-P2-7 — `llm-log-exporter` PodMonitor selector is broader than intended (matches gateway + postgres pods)**
- File: `k8s/apps/monitoring/values/kube-prometheus-stack.yaml:113-117`
- What's wrong: the selector `app.kubernetes.io/part-of: ai` matches the litellm and postgres pods too; only model pods expose the `log-exporter` container port (9399). The operator silently skips pods without the named port, so no broken targets — but same selector-hygiene issue as F-P2-6.
- Fix: use the same distinguishing label as F-P2-6 (e.g. `app.kubernetes.io/component: model` on the model pod template in model-deployment.yaml) and select on it.

**F-P2-8 — LiteLLM metrics path relies on a 307 redirect**
- File: `k8s/apps/monitoring/values/kube-prometheus-stack.yaml:98` (`path: /metrics`)
- What's wrong: `k8s/apps/monitoring/llama-metrics.md` documents the gateway endpoint as `/metrics/` — "note trailing slash, 307 without it". The shared `ai-fleet` endpoint scrapes `/metrics` for the litellm Service too; it only works because Prometheus follows redirects. A future LiteLLM change (or a client that doesn't follow redirects) breaks the gateway scrape with no local signal.
- Fix: split the `ai-fleet` monitor into two endpoints/monitors — `litellm` with `path: /metrics/` and the model Services with `path: /metrics` (both keep `bearerTokenFile: /prometheus/llm-api-key/token`; the gateway ignores the token per `require_auth_for_metrics_endpoint: false`).

**F-P2-9 — DCGM: no `customMetrics` KPI list (chart default ~40-field list exported)**
- File: `k8s/apps/monitoring/values/dcgm-exporter.yaml` (whole file)
- What's wrong: research §5.5: "Set the KPI list to only the metrics you plot." The values file sets no `customMetrics`, so the chart's default DCGM field list is exported. The dashboards only plot `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`, `DCGM_FI_DEV_FB_FREE`, `DCGM_FI_DEV_MEMORY_TEMP`, `DCGM_FI_DEV_POWER_USAGE`, `DCGM_FI_DEV_SM_CLOCK`, `DCGM_FI_DEV_MEM_CLOCK` (per llama-metrics.md), all of which are in the default list — so nothing is missing, only excess series.
- Fix: add
  ```yaml
  customMetrics:
    - {default: "false", enable: "true", field: "DCGM_FI_DEV_GPU_UTIL", help: "GPU utilization (%)", metric: "DCGM_FI_DEV_GPU_UTIL", type: "gauge"}
    - {default: "false", enable: "true", field: "DCGM_FI_DEV_FB_USED", help: "Framebuffer used (MiB)", metric: "DCGM_FI_DEV_FB_USED", type: "gauge"}
    - {default: "false", enable: "true", field: "DCGM_FI_DEV_FB_FREE", help: "Framebuffer free (MiB)", metric: "DCGM_FI_DEV_FB_FREE", type: "gauge"}
    - {default: "false", enable: "true", field: "DCGM_FI_DEV_MEMORY_TEMP", help: "Memory temperature (C)", metric: "DCGM_FI_DEV_MEMORY_TEMP", type: "gauge"}
    - {default: "false", enable: "true", field: "DCGM_FI_DEV_POWER_USAGE", help: "Power usage (W)", metric: "DCGM_FI_DEV_POWER_USAGE", type: "gauge"}
    - {default: "false", enable: "true", field: "DCGM_FI_DEV_SM_CLOCK", help: "SM clock (MHz)", metric: "DCGM_FI_DEV_SM_CLOCK", type: "gauge"}
    - {default: "false", enable: "true", field: "DCGM_FI_DEV_MEM_CLOCK", help: "Memory clock (MHz)", metric: "DCGM_FI_DEV_MEM_CLOCK", type: "gauge"}
  ```
  (verify field IDs against the node's driver/CDI mode per research residual gaps).

**F-P2-10 — No explicit `resources` on any stack component**
- Files: `values/kube-prometheus-stack.yaml` (no `prometheus.prometheusSpec.resources` / `grafana.resources`), `values/loki.yaml` (no `singleBinary.resources`), `values/alloy.yaml` (no `alloy.resources`), `values/dcgm-exporter.yaml` (no `resources`)
- What's wrong: research §5.6: "Set explicit `resources` + `storageSpec` on every stack component (Prometheus, Grafana, Loki, Alloy) so the monitoring stack doesn't OOM the single node." All four rely on chart defaults, which are sized for generic clusters, not a single node also running 20+ GiB GPU model pods.
- Fix: set explicit requests/limits in each values file sized for mjolnir (e.g. prometheus requests 500m/2Gi, limits 2/8Gi; grafana 100m/512Mi; loki 200m/1Gi; alloy 100m/256Mi; dcgm 100m/512Mi) — tune against observed usage after a week of runtime.

---

## Per-file verdicts

| File | Verdict |
|---|---|
| `k8s/apps/monitoring/prometheus-rule.yaml` | **Does not exist** — scope note F-P2-3; the branch's only PrometheusRule is `k8s/manifests/cloud-model-rates.yaml` (below) |
| `k8s/manifests/cloud-model-rates.yaml` | **Findings** — F-P1-2 (cost math not a recording rule), F-P2-1 (naming), F-P2-2 (price staleness). Recording/alerting separation is clean (record-only, no `for:`/`severity`), `release: kps` label + `ruleSelectorNilUsesHelmValues: false` wiring is correct, 5m eval interval for constants is fine, shared record name with distinct label sets is legal |
| `k8s/apps/monitoring/values/kube-prometheus-stack.yaml` | **Findings** — F-P2-4, F-P2-5, F-P2-6, F-P2-7, F-P2-8 (+ F-P2-10). All keys valid for chart 91.7.0; retention 30d/20GB + 20Gi local-path PVC consistent; kubelet Bearer-token wiring, llm-api-key Secret ordering (created before kps apply), grafana `admin.existingSecret` + `monitoring-secrets` ordering, and alertmanager telegram config all correct; rate windows (5m/10m) ≥ 4× the 30s scrape; 5s PodMonitor interval appropriate for a ~3s-updated gauge |
| `k8s/apps/monitoring/values/loki.yaml` | **LGTM** (keys valid for loki-stack 18.13.5: Monolithic + singleBinary 1 + write/read/backend 0, RF=1, filesystem storage on the `/var/loki` PVC mount, retention 336h = 30d, tsdb/v13 schema; only shared F-P2-10 resources note) |
| `k8s/apps/monitoring/values/alloy.yaml` | **LGTM** (keys valid for alloy chart 1.13.0: `mounts.varlog`, `storagePath`, `configMap.content`; file_match → source.file → process → write pipeline correct, standard `/var/log/pods` regex, `X-Scope-OrgID: loki` matches the grafana datasource; push URL `http://loki.monitoring.svc:3100` hits the singleBinary Service directly; only shared F-P2-10 resources note) |
| `k8s/apps/monitoring/values/dcgm-exporter.yaml` | **Findings** — F-P1-3 (no explicit GPU nodeSelector/affinity), F-P2-9 (no customMetrics KPI list), F-P2-10 (resources). `runtimeClassName: nvidia` (CDI), `serviceMonitor.enabled: false` (monitor lives in kps), and pod-label RBAC trims are all correct |
| `k8s/apps/ai/templates/llama-metrics.yaml` | **Does not exist** — F-P1-1; llama.cpp metrics wiring lives in the kps values (ai-fleet ServiceMonitor: port `http` matches model/gateway Services ✓, `bearerTokenFile` path matches the Prometheus volume mount ✓; llm-log-exporter PodMonitor: port `log-exporter`/9399 matches the sidecar containerPort ✓) |
| `k8s/apps/monitoring/llama-metrics.md` | **LGTM** — consistent with research §3.7 (all `litellm_*_metric` names + `_total` counter suffixes, `litellm_spend_metric_total`, no deprecated `litellm_requests_metric`), with the dashboards' queries, and with the DCGM default KPI list; the `/metrics/` trailing-slash caveat is real and feeds F-P2-8 |

---

## Summary

The monitoring branch is structurally sound: the single PrometheusRule is clean recording-only rules wired correctly into kps, all four values files use keys valid for their pinned chart versions with sensible single-node trims (kps control-plane scrapes/alerts disabled, loki Monolithic with RF=1 on a local-path PVC, alloy as the log collector, DCGM in CDI mode), and every LiteLLM/llama.cpp/DCGM metric name in the scrape config, rules, and dashboards matches the live-verified catalog — no deprecated names, all counters carry the `_total` suffix, and all rate/increase windows respect the ≥4× scrape-interval rule. The gaps are: the per-token cost math is inlined and duplicated in the dashboard instead of being the recording rule the research brief calls for (P1); the DCGM exporter's GPU-node pinning is implicit in the chart default rather than explicit in the values (P1); the ticket's `llama-metrics.yaml` artifact doesn't exist (its function is covered by the kps values, P1); and a set of P2 hygiene items — recording-rule naming, stale comments, over-broad monitor selectors, the LiteLLM `/metrics` 307-redirect dependency, an untrimmed DCGM KPI list, and missing explicit resources across the stack. None of the P2s break current functionality; the three P1s are design-intent gaps to close before merge.
