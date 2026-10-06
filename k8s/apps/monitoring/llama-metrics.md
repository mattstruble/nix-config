# LLM fleet metric names (captured live, 2026-09-28)

Real metric names for the Grafana dashboards (6lg.5) + source tracking (6lg.7).
Captured from the running pods — do not guess from older llama.cpp docs
(pre-b10xxx builds used `llama_server_*`; b11151 uses `llamacpp:*`).

Prometheus `job` label = Service name: `gemma-4-26b-a4b`, `swift-qwen3-8-27b`,
`litellm`. Model-pod metrics carry NO labels of their own (per-pod series).

## llama.cpp (b11151, `--metrics`)

| Metric | Type | Meaning |
|---|---|---|
| `llamacpp:prompt_tokens_total` | counter | prompt tokens processed (excl. cache hits) |
| `llamacpp:prompt_tokens_cached_total` | counter | prompt tokens reused from prefix cache |
| `llamacpp:prompt_seconds_total` | counter | seconds spent processing prompts |
| `llamacpp:tokens_predicted_total` | counter | generated tokens |
| `llamacpp:tokens_predicted_seconds_total` | counter | seconds spent generating |
| `llamacpp:prompt_tokens_seconds` | gauge | avg prompt throughput (tok/s) |
| `llamacpp:predicted_tokens_seconds` | gauge | avg generation throughput (tok/s) |
| `llamacpp:requests_processing` | gauge | requests currently processing (load) |
| `llamacpp:requests_deferred` | gauge | requests waiting (LOAD QUEUE) |
| `llamacpp:n_busy_slots_per_decode` | gauge | busy slots per decode call |
| `llamacpp:n_decode_total` | counter | llama_decode() calls |
| `llamacpp:n_tokens_max` | counter | largest observed sequence length |
| `llamacpp:spec_decode_num_draft_tokens_total` | counter | MTP: draft tokens generated |
| `llamacpp:spec_decode_num_accepted_tokens_total` | counter | MTP: draft tokens accepted |
| `llamacpp:spec_decode_num_drafts_total` | counter | MTP: verification steps |

Derived:
- **TTFT** ≈ prompt processing time: `llamacpp:prompt_seconds_total / llamacpp:prompt_tokens_total` (s/token; × prompt length for per-request TTFT). No per-request TTFT histogram on the pod.
- **Decode tok/s**: `rate(llamacpp:tokens_predicted_total[5m])` (or the `predicted_tokens_seconds` gauge).
- **MTP acceptance rate**: `rate(spec_decode_num_accepted_tokens_total) / rate(spec_decode_num_draft_tokens_total)`.
- **VRAM**: NOT exposed by llama-server — use DCGM: `DCGM_FI_DEV_FB_USED` (MiB), `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_MEMORY_TEMP`, `DCGM_FI_DEV_POWER_USAGE`.

### Native gauges are NOT live (verified 2026-10-05)

Live probe (14k-token prompt + 1200-token decode on gemma):
`llamacpp:predicted_tokens_seconds` stayed 0 for the entire ~45s decode and
appeared (72.74) only at completion; `llamacpp:prompt_tokens_seconds` blipped
once mid-prefill then 0. All `llamacpp:*` counters/gauges tick at completion —
rate()/gauge panels step-jump, they never show the live rate. (This is why the
live-rate panels use the log-exporter sidecar below — do NOT repoint them to
native metrics again.)

## Live rates: log-exporter sidecar (9399)

`llamacpp_live_decode_tps` / `llamacpp_live_prefill_tps` (gauges, labels
`model` + `pod`) come from the log-exporter sidecar (`log-exporter-configmap.yaml`):
it tails the model's `/var/log/llama.log` (the model container redirects stdout
there; the sidecar echoes each line to its own stdout so Alloy still ships logs
to Loki) and parses the live rate lines (`tg_3s = N t/s` /
`prompt processing ... N tokens per second`). Scraped by the `llm-log-exporter`
PodMonitor at 5s. The `model` label = **deployment name** (== Prometheus `job`
label), NOT `modelName` (the dotted gateway name) — the dashboard `$model` var is
job-sourced. Gauges decay to 0 after 5s without a log line.

## LiteLLM gateway (`/metrics/` — note trailing slash, 307 without it)

All counters carry labels: `model` (token metrics) / `requested_model` (request
metrics), `api_key_alias`, `hashed_api_key`, `client_ip`, `user_agent`,
`model_id`, `status_code`, `route`, `api_provider`, `user`, `team`, `org_id`,
`end_user`, `user_email`, `org_alias`, `team_alias`. Note: `client_ip`,
`user_agent`, `end_user`, and `user_email` are dropped at scrape time by the
litellm ServiceMonitor's `metricRelabelings` (see kps values); they are not
available in Prometheus.

| Metric | Type | Meaning |
|---|---|---|
| `litellm_proxy_total_requests_metric_total` | counter | requests (label `requested_model`, `status_code`) |
| `litellm_proxy_failed_requests_metric_total` | counter | failed requests |
| `litellm_total_tokens_metric_total` | counter | total tokens (label `model`) |
| `litellm_input_tokens_metric_total` | counter | input/prompt tokens |
| `litellm_output_tokens_metric_total` | counter | output tokens |
| `litellm_input_cached_tokens_metric_total` | counter | cached input tokens |
| `litellm_input_cache_creation_tokens_metric_total` | counter | cache-creation tokens |
| `litellm_llm_api_time_to_first_token_metric` | histogram | **real per-request TTFT** (gateway-side) |
| `litellm_request_total_latency_metric` | histogram | end-to-end request latency |
| `litellm_llm_api_latency_metric` | histogram | LLM API latency |
| `litellm_spend_metric_total` | counter | spend (all $0 for local models) |

- **Per-source tracking (6lg.7)**: the `api_key_alias` label is already emitted
  (currently `"None"` — the shared placeholder key has no alias). Creating
  LiteLLM keys with `--key-alias pi` / `--key-alias opencode` populates it;
  no gateway config change needed for the label itself.
- Cardinality note: `model_id` is a high-cardinality label; `client_ip` and
  `user_agent` are dropped at scrape time (see above), so they never reach
  Prometheus. Trim `model_id` via `prometheus_label_config` if the series
  count ever hurts.

## Cloud model rates (`ai:cloud_model:rates`, PrometheusRule)

`k8s/manifests/cloud-model-rates.yaml` records per-model cloud API pricing as
constant gauges: `ai:cloud_model:rates{profile, token_type}` in USD per 1M
tokens. `token_type` is pinned to `{input, cached, output}`; `profile` is the
cloud model name. The current rates live in the manifest's header comment —
that block is the single source of truth (including the procedure for
updating them), so no rate table is duplicated here.

Used by the `mjolnir LLM overview` dashboard's `rate_profile` variable to
cost tokens per type: input (excl. cached) × input rate + cached × cached rate
+ output × output rate. Cached tokens are a subset of input (OpenAI
`prompt_tokens` convention).

## DCGM (dcgm-exporter, job `dcgm-exporter`)

`DCGM_FI_DEV_GPU_UTIL` (%), `DCGM_FI_DEV_FB_USED` / `DCGM_FI_DEV_FB_FREE` (MiB),
`DCGM_FI_DEV_MEMORY_TEMP` (°C), `DCGM_FI_DEV_POWER_USAGE` (W),
`DCGM_FI_DEV_SM_CLOCK` / `DCGM_FI_DEV_MEM_CLOCK` (MHz). Label `gpu` = index.
