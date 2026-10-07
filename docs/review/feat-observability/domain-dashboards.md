# Domain review: Grafana dashboards (3 JSON)

**Ticket:** mestruble-3x7.2 — "[review] Domain review: Grafana dashboards (3 JSON)"
**Repo:** /Users/mestruble/Software/nix-config (branch `feat/observability`)
**Date:** 2026-10-04
**Scope:**
- `k8s/apps/monitoring/dashboards/cluster-overview.json` (uid `mjolnir-cluster`)
- `k8s/apps/monitoring/dashboards/llm-fleet.json` (uid `mjolnir-llm-fleet`)
- `k8s/apps/monitoring/dashboards/llm-overview.json` (uid `mjolnir-llm-overview`)

**Method:** Every PromQL target in every panel checked against (a) the live-verified LiteLLM metric names in `docs/review/feat-observability/research.md` §3.7, (b) the live-captured llama.cpp/DCGM names in `k8s/apps/monitoring/llama-metrics.md`, (c) the `cloud_model_rates` PrometheusRule in `k8s/manifests/cloud-model-rates.yaml`, (d) PromQL semantics (counter `_total` suffix, histogram `_bucket`, rate/increase windows, `$__range` = milliseconds), and (e) Grafana dashboard best practices (research.md §4: stable uid, panel type fit, variable wiring, transformations, time range/refresh). Cross-checked chart/deploy facts: ai chart applies to the `default` namespace (no `--namespace` in `nix/services/k3s.nix`), model Deployment names equal the model/job name, and the fixed `prometheus`/`loki` datasource uids are deliberate (comment in `k8s/apps/monitoring/values/kube-prometheus-stack.yaml`).

---

## Findings

### P0

**P0-1 — llm-fleet.json:97 — panel 128 "Decode tokens/s" queries a metric that does not exist**
`sum by (model) (llamacpp_live_decode_tps{model=~"$model"})` — `llamacpp_live_decode_tps` is not a real metric. `llama-metrics.md` (captured live from the running pods) lists decode throughput as the gauge `llamacpp:predicted_tokens_seconds` (or `rate(llamacpp:tokens_predicted_total[5m])`). The panel renders empty.
**Fix:** `"expr": "sum by (job) (llamacpp:predicted_tokens_seconds{job=~\"$model\"})"` (see P1-1 for the label part of the same fix).

**P0-2 — llm-fleet.json:177 — panel 129 "Prompt tokens/s (prefill)" queries a metric that does not exist**
`sum by (model) (llamacpp_live_prefill_tps{model=~"$model"})` — `llamacpp_live_prefill_tps` is not a real metric. The live-captured name is `llamacpp:prompt_tokens_seconds` (gauge, avg prompt throughput tok/s).
**Fix:** `"expr": "sum by (job) (llamacpp:prompt_tokens_seconds{job=~\"$model\"})"`.

### P1

**P1-1 — llm-fleet.json:97,177 (legendFormat :98,:178) — `model` label does not exist on llamacpp metrics**
`llama-metrics.md`: "Model-pod metrics carry NO labels of their own (per-pod series)" — the only labels are `job`/`instance` from the scrape config. `model=~"$model"` therefore matches nothing, and `sum by (model)` + `legendFormat: "{{job}}"` would produce a single series with an empty legend even if the metric names were fixed. Every other llamacpp panel in the same dashboard correctly uses `job=~"$model"`.
**Fix:** in both panels use `sum by (job) (...) {job=~"$model"}` (as folded into the P0-1/P0-2 fixes above).

**P1-2 — llm-fleet.json:517 — panel 134 "MTP acceptance" divides raw cumulative counters**
`sum by (job) (llamacpp:spec_decode_num_accepted_tokens_total{...}) / sum by (job) (llamacpp:spec_decode_num_draft_tokens_total{...})` — a ratio of cumulative counters since process start, not the current acceptance rate (and it drifts as the counters age). `llama-metrics.md` gives the exact formula: `rate(spec_decode_num_accepted_tokens_total) / rate(spec_decode_num_draft_tokens_total)`.
**Fix:** `"expr": "sum by (job) (rate(llamacpp:spec_decode_num_accepted_tokens_total{job=~\"$model\"}[5m])) / sum by (job) (rate(llamacpp:spec_decode_num_draft_tokens_total{job=~\"$model\"}[5m]))"`.

**P1-3 — cluster-overview.json:914,1168,1262 — `percentunit` unit on raw core values (3 panels)**
Panels 116 "CPU use by namespace" (expr :948), 120 "Pods CPU usage" (expr :1202), 122 "Containers CPU usage" (expr :1296) all plot `sum(rate(container_cpu_usage_seconds_total[5m])) by (...)`, which yields **cores**, but the field unit is `percentunit` (0–1 = 0–100%). A pod using 0.5 cores displays as 50%; on a multi-core node the stacked panel 116 totals far above 100%. Misleading values, not just cosmetics.
**Fix (per panel):** either divide by core count to make a true fraction, e.g. panel 116: `sum by (namespace) (rate(container_cpu_usage_seconds_total{image!=\"\",node=~\"^$Node$\",namespace=~\"$Namespace\"}[5m])) / sum(machine_cpu_cores{node=~\"^$Node$\"})` (keep `percentunit`), or change the unit to `short` and rename the panels "(cores)".

### P2

**P2-1 — llm-fleet.json:1618–1626 — `model` variable is job-based but labeled "Model (pod)"**
`label_values(llamacpp:tokens_predicted_total, job)` yields job/service names (`gemma-4-26b-a4b`, …). It works with `job=~"$model"` and with the Loki `pod=~"($model).*"` (Deployment name = model name), but the label is misleading and is the root cause of the P0/P1 label mismatches in panels 128/129.
**Fix:** rename the variable label to "Model (job)" (and keep all queries on `job`), or define it from pod names if per-pod semantics are wanted.

**P2-2 — llm-fleet.json:1602 — Loki "Model logs" with `$model`=All matches every pod in the namespace**
`{namespace="default", pod=~"($model).*"}` with `allValue: ".*"` becomes `pod=~"(.*).*"` — the "Model logs" panel then also shows postgres/gateway logs. (`namespace="default"` itself is correct — the ai chart is applied without `--namespace`.)
**Fix:** anchor to the model-pod prefix, e.g. `pod=~".*($model).*"` is not enough; use a label/regex that excludes non-model pods, e.g. `{namespace="default", pod=~"($model)-.*"}` (pods are `<model>-<rs>-<hash>`).

**P2-3 — cluster-overview.json — no top-level `refresh`**
Auto-refresh is off (key absent). Research §4.6 recommends 30s–1m for a live cluster dashboard.
**Fix:** add `"refresh": "30s"` at top level.

**P2-4 — llm-fleet.json — no top-level `refresh`**
Same as P2-3.
**Fix:** add `"refresh": "30s"` at top level.

**P2-5 — llm-overview.json:1325 — `"refresh": ""` disables auto-refresh on a live command center**
The dashboard is described as a "command center … live inference load" and ships a `timepicker.refresh_intervals` list, but refresh is explicitly off.
**Fix:** `"refresh": "30s"` (or `"1m"`).

**P2-6 — llm-overview.json:22 — hardcoded `"id": 3238731674816512`**
The other two dashboards use `"id": null`. A fixed DB id in a file-provisioned dashboard risks id collisions on import/provision (Grafana matches by `uid`; `id` should be assigned by the instance).
**Fix:** `"id": null`.

**P2-7 — cluster-overview.json:1037 — "Network I/O" panel only shows receive**
Panel 118 has a single target (`container_network_receive_bytes_total`, legend "Received"); the title promises I/O both ways.
**Fix:** add a second target: `"expr": "sum(rate(container_network_transmit_bytes_total{node=~\"^$Node$\"}[5m]))", "legendFormat": "Transmitted"`.

**P2-8 — cluster-overview.json:89 — "Node Status" panel uses `kube_node_info`**
`kube_node_info` is 1 whenever node-exporter is scraped — it indicates scrape liveness, not node readiness.
**Fix:** `"expr": "kube_node_status_condition{condition=\"Ready\"}"` (1 = Ready, 0 = NotReady) with the existing 0/1 thresholds; keep `legendFormat: "{{node}}"`.

**P2-9 — cluster-overview.json:172 — cluster CPU gauge includes pause containers**
`sum(rate(container_cpu_usage_seconds_total{node=~\"^$Node$\"}[5m]))` lacks the `image!=""` filter that every other container-CPU panel in this dashboard uses (pause-container CPU is ≈0, so impact is negligible — consistency only).
**Fix:** `sum(rate(container_cpu_usage_seconds_total{image!=\"\",node=~\"^$Node$\"}[5m]))`.

---

## Per-dashboard verdicts

- **cluster-overview.json — FINDINGS (1×P1, 5×P2).** Structure is sound: stable uid, schemaVersion 39, now-6h default, `Node`/`Namespace` variables correctly wired (`^$Node$` / `$Namespace` with `allValue: ".*"`), sensible panel types. The `percentunit`-on-cores bug (P1-3) is the only real display bug; rest are minor.
- **llm-fleet.json — FINDINGS (2×P0, 2×P1, 3×P2).** The two top throughput panels (128/129) are empty (nonexistent metrics + nonexistent `model` label) and the MTP acceptance stat (134) computes a ratio of raw counters. Everything else checks out: all LiteLLM gateway queries use the verified names with `_total`/`_bucket` suffixes and correct `le`-preserving histogram quantiles; DCGM panels and the Loki panel (namespace `default`, pod prefix = model name) are correct; `increase(...[$__range])` usage is appropriate; stable uid.
- **llm-overview.json — LGTM with 2 minor findings (2×P2).** All LiteLLM metric names verified against §3.7; the `$__range / 3600000` electricity math is correct (ms→h, no 1000× bug); the cloud-cost formula matches the documented cached⊂input convention and the `cloud_model_rates` rule labels; the per-model table's labelsToFields → merge → groupingToMatrix → organize pipeline is the correct matrix pattern; `rate_profile`/`elec_rate` variables wired correctly. Only the hardcoded `id` and disabled refresh need attention.

---

## Summary

The three dashboards are structurally solid — stable slug uids, correct schema versions, sensible default ranges, variables wired with `allValue: ".*"`, correct panel-type choices, and (in the two LiteLLM-facing dashboards) metric names that match the live-verified LiteLLM catalog exactly, including the `_total` counter suffix and `_bucket` histogram usage with `le` preserved in `histogram_quantile`. The `$__range` arithmetic in llm-overview divides by 3600000 (milliseconds→hours) as it should. The real defects are concentrated in llm-fleet.json: its two headline throughput panels query metrics that do not exist in the live-captured llama.cpp catalog (`llamacpp_live_decode_tps`/`llamacpp_live_prefill_tps` instead of `llamacpp:predicted_tokens_seconds`/`llamacpp:prompt_tokens_seconds`) and filter on a `model` label the pods never emit (only `job`), so they render empty; the MTP acceptance stat divides raw cumulative counters instead of using the documented `rate()/rate()` formula. In cluster-overview.json, three CPU panels display raw core values with a `percentunit` unit, making the numbers misleading (50% for half a core, stacked totals >100%). The remainder is housekeeping: missing/disabled auto-refresh on all three dashboards, a hardcoded dashboard `id` in llm-overview, a receive-only "Network I/O" panel, `kube_node_info` as a readiness proxy, and a mislabeled `model` template variable. No P0/P1 issues affect the LiteLLM gateway or cost panels, which are the dashboards' core value.
