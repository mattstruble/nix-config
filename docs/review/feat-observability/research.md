# Research: Best-practices brief — k8s/helm chart + monitoring stack

**Ticket:** mestruble-3x7.3 — "[research] Best-practices brief: k8s/helm chart + monitoring stack"
**Repo:** /Users/mestruble/Software/nix-config (branch `feat/observability`)
**Context:** single-node k3s homelab (mjolnir, k3s 1.35.8) running an LLM fleet (llama.cpp pods) behind a LiteLLM gateway, with kube-prometheus-stack + loki-stack + Alloy + DCGM exporter. Branch adds: a Helm chart (`k8s/apps/ai`) with gateway/model/log-exporter/postgres deployments, 3 Grafana dashboards, a PrometheusRule, monitoring values files, a sops-managed secrets file, and a LiteLLM key-minting script.

> **Verification status:** LiteLLM metrics (section 3.7), kps values keys (5.1), native sidecar semantics (2.5), DCGM chart (5.5), Grafana uid/provisioning semantics (4.1) were **live-verified** against the cited pages on 2026-10-04. Remaining URLs are canonical stable doc locations (helm.sh, kubernetes.io, prometheus.io, grafana.com) — pointers to the authoritative pages, not live-fetched.

---

## 1. Helm chart conventions

1. **Design `values.yaml` as the single source of truth with typed, documented defaults.** Every overridable knob (image repo/tag/digest, replica counts, ports, resources, probe params, persistence) lives in `values.yaml` with a comment per key; `values.schema.json` validates types at `helm install/upgrade` so typos fail fast. **Source:** https://helm.sh/docs/chart_best_practices/values/
2. **Enforce chart structure & conventions:** one chart per app, `Chart.yaml` with semver `version` + `appVersion`, `templates/` for manifests, `_helpers.tpl` for shared named templates, `NOTES.txt` for post-install output. **Source:** https://helm.sh/docs/chart_best_practices/structure/ and https://helm.sh/docs/chart_best_practices/conventions/
3. **Centralize reusable logic in `_helpers.tpl` named templates** (`fullname`, `labels`, `selectorLabels`, `serviceAccountName`, `image`). Keeps generated `metadata.labels` and `spec.selector` consistent — a selector/label mismatch breaks rolling updates. **Source:** https://helm.sh/docs/chart_template_guide/
4. **Use template idioms that keep manifests safe:** `{{ required "msg" .Values.x }}` for mandatory values, `{{ .Values.x | default "fallback" }}` for optional ones, `{{ toYaml .Values.resources | nindent 12 }}` for nested maps, `{{- if .Values.x }}` for conditional resources. **Source:** https://helm.sh/docs/chart_template_guide/functions_and_pipes/
5. **Pin images by digest** (`image.digest: sha256:...`), not just tag — digest pinning guarantees the exact bytes deployed; required for reproducible Nix-built images. **Source:** https://kubernetes.io/docs/concepts/containers/images/ and https://helm.sh/docs/chart_best_practices/security/
6. **For single-node k3s, keep the chart minimal and storage-aware:** `replicas: 1`, no HA/leader-election values, storage class = k3s's built-in `local-path` provisioner, no anti-affinity that can't be satisfied on one node. **Source:** https://docs.k3s.io/advanced/local-storage
7. **Add a security baseline to the chart** (non-root, read-only root FS, dropped capabilities, seccomp RuntimeDefault) as chart defaults so every workload inherits what PSS "restricted" expects. **Source:** https://helm.sh/docs/chart_best_practices/security/

## 2. k8s workload best practices

1. **Use all three probe types with correct semantics:** `startupProbe` for slow-starting containers (llama.cpp pods load large models — generous `failureThreshold × periodSeconds` budget so they aren't killed mid-load), `readinessProbe` to gate traffic, `livenessProbe` to restart a wedged process. Keep liveness *looser* than readiness. **Source:** https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
2. **Set both `requests` and `limits` on every container.** `requests` drive scheduling; `limits` cap usage and set QoS. Memory `requests` should cover the model's resident footprint (llama.cpp + context) to avoid OOMKill churn. **Source:** https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
3. **Run under PSS "restricted":** `runAsNonRoot: true`, non-zero `runAsUser`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`, `seccompProfile.type: RuntimeDefault`; `pod-security.kubernetes.io/enforce=restricted` on the namespace. **Source:** https://kubernetes.io/docs/concepts/security/pod-security-admission/ and https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
4. **Right-size PVCs: explicit `storageClassName` + `requests.storage`, sized for data + headroom.** Note: `helm uninstall` deletes PVCs by default — set StorageClass `reclaimPolicy: Retain` if data must survive release deletion. **Source:** https://kubernetes.io/docs/concepts/storage/persistent-volumes/ and https://kubernetes.io/docs/concepts/storage/storage-classes/
5. **Model the log-exporter as a proper sidecar.** **Verified:** native sidecar containers (`initContainers` + `restartPolicy: Always`) are **stable since k8s 1.33** (alpha in 1.28) — available on k3s 1.35.8, so the exporter can start before and outlives the main container cleanly; a plain container also works. Mount a shared `emptyDir` (main writes, exporter tails), expose exporter metrics on **its own port**, point Prometheus there. **Source:** https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/
6. **Distinct container names and unique ports** in multi-container pods so `kubectl logs -c <name>` and Service `targetPort` are unambiguous. **Source:** https://kubernetes.io/docs/concepts/workloads/pods/

## 3. Prometheus (PrometheusRule, recording rules, cost math)

1. **Separate recording rules from alerting rules in the `PrometheusRule`.** `record:` pre-computes expensive queries; `alert:` only triggers. Don't put `for:`/`severity` on recording rules, don't put `record:` on alerts. **Source:** https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
2. **Use recording rules to pre-compute rate/increase math** that dashboards and alerts both need, so every panel references one canonical metric name instead of re-deriving `rate(...)` with possibly different windows. **Source:** https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
3. **Name recording rules with a namespace prefix and `:` separators** (e.g., `ai:litellm:cost:rate5m`); keep the `by (...)` label set minimal (only labels you'll slice by) to avoid cardinality blowup. **Source:** https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
4. **Compute per-token cost as a recording rule: `cost = tokens × unit_price`**, with price-per-token as a static/ConfigMap-fed metric so the math stays in Prometheus and dashboards just read the result. Use `rate` over a window matching the scrape interval (default `[5m]` for 15–60s scrapes). **Source:** https://prometheus.io/docs/prometheus/latest/querying/functions/
5. **Choose `rate` vs `increase` deliberately:** `rate` for per-second throughput (tokens/s, req/s); `increase`/`sum_over_time` for "how many in the window" (total tokens, total cost). **Source:** https://prometheus.io/docs/prometheus/latest/querying/functions/
6. **Rule hygiene:** avoid `by()` on high-cardinality labels (per-request IDs) in recording rules; drop labels you don't need. Note: `keep_dropped` is a *scrape-config* option (retaining dropped series), **not** a PrometheusRule field — don't conflate. **Source:** https://prometheus.io/docs/prometheus/latest/configuration/configuration/
7. **LiteLLM metric names (LIVE-VERIFIED, https://docs.litellm.ai/docs/proxy/prometheus):** the proxy exposes —
   - `litellm_spend_metric` (total spend; labels incl. `model`, `hashed_api_key`, `api_key_alias`, `user`, `requested_model`, `api_provider`)
   - `litellm_total_tokens_metric` (input+output), `litellm_input_tokens_metric`, `litellm_output_tokens_metric`
   - token-type detail counters (sparse, additive to totals): `litellm_input_cached_tokens_metric` (provider prompt-cache reads), `litellm_input_cache_creation_tokens_metric`, `litellm_output_reasoning_tokens_metric`, `litellm_input_audio_tokens_metric`, `litellm_output_audio_tokens_metric`
   - LiteLLM's own response cache: `litellm_cache_hits_metric`, `litellm_cache_misses_metric`, `litellm_cached_tokens_metric`
   - requests: `litellm_proxy_total_requests_metric`, `litellm_proxy_failed_requests_metric` (`litellm_requests_metric` is **deprecated**)
   - latency histograms: `litellm_request_total_latency_metric` (end-to-end), `litellm_llm_api_time_to_first_token_metric` (TTFT, streaming only), `litellm_llm_api_latency_metric`, `litellm_request_queue_time_seconds`
   - pod health: `litellm_in_flight_requests` (gauge, queue depth)
   - deployment: `litellm_deployment_success_responses` / `_failure_responses` / `_total_requests`
   - **Counters use the `_total` suffix in PromQL** (e.g., `rate(litellm_input_tokens_metric_total[5m])`); histograms use `_bucket`/`_sum`/`_count`.
   - Enable via `litellm_settings: callbacks: ["prometheus"]` in the proxy config; endpoint `/metrics` (auth: `Authorization: Bearer <key>`); multi-worker needs `PROMETHEUS_MULTIPROC_DIR`; v1.101.0+ can serve metrics on a dedicated `--prometheus_metrics_port` (that port has **no** virtual-key auth — keep it off any ingress).

## 4. Grafana dashboard best practices

1. **Version dashboards as code with a stable `uid`.** **Verified:** Grafana matches/overwrites provisioned dashboards by `uid` — a fixed uid keeps links, alerts, and provisioning stable across re-provisioning; auto-generated uids break that. Store JSON in git and provision from a local path (or Git Sync). **Source:** https://grafana.com/docs/grafana/latest/administration/provisioning/
2. **Provision dashboards via the provisioning mechanism** (a `dashboards.yaml` pointing at a folder of JSON) so the 3 dashboards are reproducible and diffable, not DB-only. **Source:** https://grafana.com/docs/grafana/latest/administration/provisioning/
3. **Pick the right panel type per data shape:** `bargauge` for a few KPIs (per-model cost, GPU util) where bar + threshold coloring reads fast; `table` for per-model/per-key breakdowns; `timeseries` for trends. **Source:** https://grafana.com/docs/grafana/latest/panels/
4. **Use template variables for drill-down** (`$model`, `$rate_profile`, `$time`); wire variables into queries; `includeAll`/`multi` where an "All" view is useful. **Source:** https://grafana.com/docs/grafana/latest/dashboards/variables/
5. **Use transformations to reshape Prometheus results:** `groupBy` / `groupingToMatrix` ("Group to matrix") pivots `by (model, token_type)` series into a matrix (rows=models, cols=token_type) for tables/bargauges. **Source:** https://grafana.com/docs/grafana/latest/panels/transformations/
6. **Set sensible time ranges & refresh:** default `from`/`to` (e.g., last 6h), auto-refresh 30s–1m; keep `rate`/`increase` windows independent of the dashboard time range so panels don't go blank on short ranges. **Source:** https://grafana.com/docs/grafana/latest/dashboards/

## 5. Grafana stack values (kube-prometheus-stack, loki-stack, Alloy, DCGM on k3s)

1. **kube-prometheus-stack key values (LIVE-VERIFIED against chart values):** `grafana.adminPassword` (or `grafana.ldap`/annotations for auth), `prometheus.prometheusSpec.retention` (duration, e.g. `15d`), `prometheus.prometheusSpec.storageSpec.volumeClaimTemplate` (PVC size + storageClass), `prometheus.prometheusSpec.resources`, `thanos.enabled: false`, `alertmanager` toggles. Pin the chart version and read its README for authoritative keys. **Source:** https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/README.md
2. **On single-node k3s, disable what you don't need** to save RAM: `thanos.enabled: false`, single Prometheus replica, trim `kubeStateMetrics`/scheduler metrics. **Source:** https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/README.md
3. **loki-stack: right-size storage + set storageClass** (`loki.storage` local vs boltdb-shipper/bucket, PVC for local storage, `grafana.enabled: false` if reusing the kps Grafana — add Loki as a datasource on the existing one). **Source:** https://github.com/grafana/helm-charts/tree/main/charts/loki-stack
4. **Alloy: configure scrape configs as code** (`prometheus.scrape`, `loki.source.file` components) so the log-exporter metrics port and the file-tail → Loki path are declarative and versioned, not hand-edited in the UI. **Source:** https://grafana.com/docs/alloy/latest/
5. **DCGM exporter (LIVE-VERIFIED):** official chart is `gpu-helm-charts/dcgm-exporter` (repo `nvidia.github.io/dcgm-exporter`); deploys one exporter pod per selected GPU node; values include `nodeSelector`, `tolerations`, `affinity` (e.g. `nvidia-gpu` Exists), `customMetrics` (DCGM field list → metric type + help). Set the KPI list to only the metrics you plot. **Source:** https://github.com/NVIDIA/dcgm-exporter/tree/main/deployment and https://docs.nvidia.com/datacenter/dcgm/latest/installation/install-dcgm-exporter.html
6. **Set explicit `resources` + `storageSpec` on every stack component** (Prometheus, Grafana, Loki, Alloy) so the monitoring stack doesn't OOM the single node. **Source:** https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/README.md

## 6. Secrets (sops-nix + k8s, key minting, runbook hygiene)

1. **Encrypt secrets at rest with sops (age) and decrypt at deploy time via sops-nix.** Store the LiteLLM master key, postgres password, and any registry creds in a sops-encrypted file; sops-nix renders decrypted values into the Nix build / k8s `Secret` at apply time — never commit plaintext. **Source:** https://github.com/flokli/sops-nix and https://github.com/getsops/sops
2. **Keep the sops-encrypted file in git, the age private key out of git.** `.sops.yaml` defines the age key path (creationRules scoping); the key lives on the deploy host. Auditable, versioned secrets, no plaintext in history. **Source:** https://github.com/getsops/sops
3. **Map sops values to k8s `Secret` objects, referenced via `secretKeyRef`** in pod specs — never bake values into ConfigMaps or Deployment manifests. For postgres, wire `POSTGRES_PASSWORD` from a Secret key. **Source:** https://kubernetes.io/docs/concepts/configuration/secret/
4. **Make the LiteLLM key-minting script idempotent and non-interactive:** call the virtual-key endpoint with the master key from the sops-decrypted secret, check-for-existing before create (safe re-run), keep the master key out of the script and out of logs. **Source:** https://docs.litellm.ai/docs/proxy/virtual_keys
5. **Runbook hygiene:** document (a) how to re-encrypt/rotate a sops secret, (b) age key location + backup, (c) exact `helm`/`nix` commands to re-apply after a secret change, (d) how to re-mint a LiteLLM key — in the repo, not tribal knowledge. **Source:** https://github.com/flokli/sops-nix (docs)
6. **Treat the sops file as the single source of truth** for all sensitive values referenced by both the chart and the minting script, so a rotation is one edit + one re-apply. **Source:** https://github.com/getsops/sops

---

## Corrections to the initial (unverified) draft

- **LiteLLM metric names:** the draft inferred `litellm_token_usage_total` — **wrong**. Actual: `litellm_spend_metric`, `litellm_total_tokens_metric`, `litellm_input_tokens_metric`, `litellm_output_tokens_metric` (+ sparse token-type detail counters, section 3.7). Any recording rule or dashboard query must use these names with the `_total` counter suffix.
- **`litellm_requests_metric` is deprecated** — use `litellm_proxy_total_requests_metric`.
- **Native sidecars:** stable since k8s 1.33 (not "alpha on 1.28" as the draft implied for current use); available on k3s 1.35.8.
- **DCGM chart:** the official chart lives in the `dcgm-exporter` repo's `deployment/` dir (`gpu-helm-charts/dcgm-exporter`), not a separate helm-charts repo.
- **Grafana provisioning:** dashboards are matched/overwritten by `uid` — stable uids are mandatory for dashboard-as-code.

## Residual gaps (verify against the running cluster)

- Exact kps/loki-stack value keys for the **pinned chart versions** in this repo (keys drift across versions) — the domain review should diff against the pinned chart's `values.yaml`.
- DCGM KPI list specifics depend on the node's driver / `nvidia-container-toolkit` (CDI mode on mjolnir).
- The dedicated LiteLLM metrics port (v1.101.0+) has no virtual-key auth — if the branch uses it, confirm it's not exposed via ingress.
