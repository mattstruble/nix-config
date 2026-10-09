# Branch analysis: `feat/qwen-strata` vs `main`

Reviewed 2026-10-08. Range `4dfac16..5362931` (6 commits, 7 files, +444/−12).
Sources: upstream `Niko1221/Strata` @ `fb58e0d` (cloned, read against the diff), nixpkgs CUDA
docs, Helm chart best practices, NVIDIA/k8s GPU + graceful-shutdown guidance.

## What the branch does

| File | Change |
| --- | --- |
| `nix/hosts/mjolnir/_strata.nix` (+153) | New package: Strata 0.1.40.3 C++ engine (cmake/CUDA, sm_75) + `python3.withPackages` env + server source + a generated `docker-entrypoint.sh`, bundled into one store path. |
| `nix/hosts/mjolnir/default.nix` (+17) | `system.build.strata` + a `systemd.tmpfiles` GC root for the bundle. |
| `k8s/apps/ai/templates/strata-deployment.yaml` (+210) | New engine-specific Deployment template for `engine: strata` models. |
| `k8s/apps/ai/templates/model-deployment.yaml` (+1/−1) | Guard: skip llama deployments whose engine is strata. |
| `k8s/apps/ai/values/flash-next-strata-iq4xs.yaml` (+39) | The model entry (GPU 1, port 8558, pinned store path). |
| `k8s/apps/ai/values/gemma-4-26b-a4b.yaml` (+4/−1) | gemma disabled to free GPU 1. |
| `k8s/apps/ai/templates/log-exporter-configmap.yaml` (+20/−10) | Two strata log regexes; the parse loop became a 4-tuple table. |

Wiring that needed no change and works (verified by `helm template` + reading the selectors):
the gateway `model_list`, the per-model Service, the netpol (no port filter) and the
`llm-log-exporter` PodMonitor (`part-of: ai`) all pick the new pod up from its labels alone.
`helm lint` clean, `helm template` renders 2 models + gateway + postgres.

## Findings, ranked

### F1 · High · the log-exporter sidecar is redundant for strata — upstream ships native Prometheus metrics
`serve/prometheus.py` renders `GET /metrics` in Prometheus text format, including
`strata:live_tok_s` (decode over the last seconds) and `strata:live_prefill_tok_s_mean`, plus
vLLM-named counters/histograms (`vllm:generation_tokens_total`, `vllm:inter_token_latency_seconds`, …).
Upstream also ships `docs/monitoring/{prometheus.yml,servicemonitor.yaml,grafana-strata.json}` —
a ServiceMonitor for exactly this pod shape, with the API key as a bearer token.

The branch instead extends the log-tailing sidecar (2 new regexes + a 4-way match loop) and keeps a
`python:3.12-alpine` sidecar in the strata pod to re-derive, from stdout, numbers the server
publishes natively per scrape. The sidecar exists because llama.cpp's native gauges only tick at
request completion (`k8s/apps/monitoring/llama-metrics.md` says so explicitly); that premise does
not hold for strata.

Migration cost, so the cut is honest: `strata:` names contain a colon, so PromQL needs
`{__name__="strata:live_tok_s"}`; the dashboards key off `llamacpp_live_*_tps`; `/metrics` is
auth-gated (`_authorized()`), so the monitor needs the `llm-api-key` bearer secret the llama
ServiceMonitor already uses. See ponytail-audit finding 2.

### F2 · High · the memory-limit contract is stated nowhere in git
Upstream, verbatim (`docs/INSTALL.md:124`): *"A memory limit needs `-e LOW_RAM=on`, which maps the
model's experts from the pack instead of keeping them in RAM: setup.py measures the host's RAM, not
the container's limit, so it cannot see a cap."*

The pod sets `memoryLimit: 80Gi` on a 96 GB host. The forked entrypoint never passes `--low-ram`
and never runs setup, so whether low-RAM mode is on is decided entirely by the config JSON on the
models PVC — a file that is not in git, not in any runbook, and not referenced by any check.
`memoryRequest: 8Gi` (vs. swift-qwen3-8-27b's 4Gi) means the scheduler admits both models on 12 Gi
of requests while the real floor is tens of GB: the limit is the only thing standing between this
pod and a cgroup OOM kill, and the knob that decides whether the limit is respected lives on a PV.

Fix is cheap either way: record the config JSON in the repo (or a `scripts/` recipe that
regenerates it) and state the low-RAM decision in the values file comment.

### F3 · Medium · the entrypoint fork silently drops upstream's env surface
Upstream `docker-entrypoint.sh` reads `FAMILY MODEL CONTEXT VISION HOST PORT API_KEY KV GPUS GPU
LAYER_SPLIT LOW_RAM GGUF_DIR RESIDENT_BUDGET_GIB KV_STREAMING CONFIG REINSTALL`. The bundle's
generated entrypoint implements `FAMILY MODEL PORT GPU API_KEY STRATA_DATA` and nothing else.
Consequences:

1. **Engine settings are out-of-band.** `CONTEXT`/`KV`/`RESIDENT_BUDGET_GIB` are recorded in the
   config JSON at setup time; upstream regenerates them with `REINSTALL=1` + env. The fork has no
   `REINSTALL`, so the only way to change 262k ctx / int8 KV / the resident budget is hand-editing
   JSON on the PVC. The values-file comment ("these are NOT env, they live in the config JSON") is
   true *of the fork*, and reads as if it were true of Strata.
2. **The deferred 2-GPU variant is blocked by the fork, not by the engine.** Upstream repeats
   `--gpus`/`--layer-split` on *every* start, with the comment that without them a single-card
   config gets re-offered to a card pair (`offer_together`). The fork passes neither, so a 2-GPU
   entry cannot pin its cards through this entrypoint.
3. **Config selection was reimplemented.** Upstream has `CONFIG=/data/config/my.json` (#1244) and
   keeps a `/opt/strata/strata-<model>.json` symlink that points into `$STRATA_DATA/config/` —
   i.e. it already handles "pick one config on a read-only install".

### F4 · Medium · `strata-deployment.yaml` is 134/210 lines (64%) byte-identical to `model-deployment.yaml`
Measured with `comm -12` on the sorted files. Strategy, labels, `terminationGracePeriodSeconds`,
pod securityContext, the 7-line container hardening block, the whole log-exporter sidecar, the
tmp/models/log/exporter-script/shm volumes and both probes are copies. Helm's own guidance is to
share this in named templates; the previous audit flagged the hardening block as a 3× repeat and
this branch is what made it 4×. A third engine today means a third 210-line file.
The copies have already drifted: probes are 45×10s here vs 30×10s there, and the strata file
carries two contradictory startupProbe comments (F5).

### F5 · Medium · stale duplicated comment in `strata-deployment.yaml`
Lines 118–129: the startupProbe rationale appears twice, first as "30 x 10s = 5 min", then as
"45 x 10s = 7.5 min; 30 x 10s was tight". One of them is wrong. While fixing: the claim that
"/health is answered before the model finishes loading" is not what upstream does — `main()` binds
the socket *after* the engine loads (`httpd = serve(svc, …)` at the end of `main()`), and
`/health` returns 200 with a `"loaded": false` field rather than a non-200. The probes are correct
for the opposite reason: nothing answers until the load finishes.

### F6 · Medium · `/tmp/strata-<epoch>` copies are never reclaimed
`WORK=/tmp/strata-$(date +%s)` then `rm -rf "$WORK"` — the `rm` targets the directory that does not
exist yet, so every start leaves ~3 MB behind (upstream `serve/` 1.4M + `tools/` 1.3M + `setup.py`
332K) in an emptyDir capped at `sizeLimit: 1Gi`. A crashloop over a few days fills the tmpfs and
the pod then fails for a reason nothing in the manifest explains. Either `rm -rf /tmp/strata-*`
first, or drop the copy entirely: `serve/server.py` takes `--config <path>` and resolves
`tools/` relative to its own location, so it can be exec'd straight from the read-only bundle with
`cd /tmp` — which is also what removes the divergence in F3.

### F7 · Medium · GC-root lifetime vs. pod lifetime (narrow window, ugly failure)
The tmpfiles root protects the bundle the *current* config builds. On the next deploy the symlink
is replaced, the previous bundle becomes unreachable, and `nix.gc` (`weekly`,
`--delete-older-than 30d`, `nix/system/nix-settings.nix:23`) can collect it. If a rollout leaves
the old pod running on the old path (failed/suspended rollout, manual hold), the bundle vanishes
underneath it up to 30 days later and the pod CrashLoops on restart — the exact failure the comment
in `default.nix` sets out to prevent, just later. Two cheap hedges: keep the previous bundle as a
second root (`strata-bundle-prev`), or gate the values path and the root on the same source (F8).

Related cost, same block: putting the bundle in `system.build` means **every** mjolnir host deploy
builds a CUDA target — the reason this host needs `nix.settings.cores = 8` and a 32 G swapfile
(both marked `ponytail`). Building it out-of-band (`nix build .#strata` + an out-link under
`/nix/var/nix/gcroots/`) decouples host activation from the GPU build and keeps the same guarantee.

### F8 · Medium · the pinned store path in values is unchecked
`binary: /nix/store/4wrhyvp6i2f5vyvvv93vrp15xrwclx00-strata-0.1.40.3` must equal what the flake
builds, and nothing verifies it — not `helm lint`, not the `k8s-manifest-diff` workflow (which only
renders `k8s/**`, so a `nix/**`-only change is untested too). A one-line CI check comparing
`nix eval .#nixosConfigurations.mjolnir.config.system.build.strata.outPath` against the values file
turns a silent CrashLoop into a red X. Same argument applies to the existing fork binaries.

### F9 · Medium · no preStop drain; the listener closes the instant SIGTERM lands
Upstream's SIGTERM handler runs `httpd.shutdown` **first**, so new connections are refused
immediately, while k8s endpoint removal and LiteLLM's view of the endpoint lag behind — requests in
that window get connection-refused rather than being served or retried upstream. The standard
mitigation for LLM pods is a short `preStop: exec: [sh, -c, "sleep 5"]` alongside the long grace
period (what kserve/llm-d do for vLLM, for the same reason). The 120 s grace itself is reasonable
— upstream documents that releasing page-locked RAM takes well over Docker's 10 s default and
recommends 60 s — and the 262k-prefill-exceeds-grace trade-off is already documented in the file.

### F10 · Low · the decode regex hardcodes the log phase names
`serve/server.py:3402` prints `f"[strata] {s['phase']}: {generated} of max {max_tokens} tokens,
{rate:.1f} tok/s, …"` — the phase is a variable. `^\[strata\] (?:answering|thinking): …` silently
stops matching the day upstream renames or adds a phase, and the gauge decays to 0 with no error
anywhere. `^\[strata\] \w+: \d+ of max \d+ tokens, ([0-9.]+) tok/s` costs nothing. Note also
`serve/server.py:407` prints one consolidated per-request line carrying *both* rates
(`… prefill X tok/s decode Y tok/s`), which is a single regex instead of two.

### F11 · Low · `image: alpine:3.20` is a floating tag
Every other model pins an exact tag (`ghcr.io/ggml-org/llama.cpp:server-cuda12-b11151`), and this
repo's own docs carry the scar tissue: *"floating `server-cuda` tag changed flash-attn behavior …
never run 3.6 on an unpinned tag"* (`docs/cluster-overview.md:127`). Here the image only supplies
`sh` + coreutils, but a refreshed tag changes the shell under a `IfNotPresent` policy. Pin by
digest.

### F12 · Low · nixpkgs CUDA packaging guidance not followed
The nixpkgs CUDA section states it in bold-ish: *"In your package's derivation arguments, it is
**strongly** recommended that the following are set: `__structuredAttrs = true; strictDeps = true;`"*
— "These settings ensure that the CUDA setup hooks function as intended." `_strata.nix` sets
neither. It builds today; it is relying on hook behaviour that is documented as depending on them.
Two smaller ones in the same file: `-DCMAKE_CUDA_ARCHITECTURES=75` is a second source of truth for
the card the host already declares as `hardware.nvidia.cudaCapabilities = [ "7.5" ]`, and the
`python3.withPackages` list is a hand-copy of upstream `requirements.txt` with nothing tying them
together across version bumps (upstream pins 8 runtime packages + 6 transitive).

### F13 · Low · documentation drift introduced by the branch
`docs/cluster-overview.md` still says **GPU 1 — gemma-4-26b-a4b**, lists flash-next among the
dormant chart models, and has no row for the strata pod or port 8558. `k8s/README.md:17` still
promises "Adding a model to the ai chart: one `values/<model>.yaml`" — no longer true: an
`engine: strata` model needs a template, a nix bundle, a pinned store path and a config JSON on a
PVC. Nothing documents how to (re)generate that config JSON, which is the artifact F2 turns on.

### F14 · Verify · two runtime assumptions worth a look at the box
- Upstream runs the container with `--ulimit memlock=-1` because the engine holds page-locked RAM;
  k8s has no equivalent and the pod inherits the runtime default. Working today, unverified.
- `/data` is mounted `readOnly`. Upstream blesses `:ro` for post-setup starts, but confirm the
  config JSON's engine `log` path is not under `/data`.

## What the branch gets right
`Recreate` (a RollingUpdate would OOM the GPU); `startupProbe` + `readinessProbe` with **no**
livenessProbe (correct for inference); `automountServiceAccountToken: false`, `drop: [ALL]`,
`seccompProfile: RuntimeDefault`, `readOnlyRootFilesystem`, non-root UID; `STRATA_EXECV=1` so
SIGTERM reaches the server as PID 1 (and the honest note that the drain still ends in SIGKILL);
pinned `fetchFromGitHub` revs with hashes and `pragma: allowlist secret` comments; the GC-root
comment that explains *why* rather than *what*; `modelName` kept so no client changes; gemma
disabled with a written re-enable recipe; the container-local GPU-index trap documented where
someone will hit it.

## Best-practice check

| Practice | Source | Status |
| --- | --- | --- |
| Publish metrics natively; scrape with a ServiceMonitor | Strata `serve/prometheus.py`, `docs/monitoring/servicemonitor.yaml` | ✗ F1 — log regexes instead |
| Memory limit ⇒ `LOW_RAM=on` | Strata `docs/INSTALL.md:124` | ✗ F2 — not expressed in git |
| Entrypoint env surface (`CONTEXT/KV/GPUS/LAYER_SPLIT/CONFIG/REINSTALL`) | Strata `docker-entrypoint.sh` | ✗ F3 — fork implements 5 of 16 |
| Graceful drain for LLM pods = preStop sleep + long grace | k8s pod lifecycle; kserve/llm-d graceful-shutdown guidance | ✗ F9 — grace only |
| `terminationGracePeriodSeconds` > engine teardown time | Strata INSTALL.md ("longer than Docker's default 10 s"; 60 s suggested) | ✓ 120 s |
| No liveness probe on long-inference pods; startup+readiness only | k8s probe guidance | ✓ |
| DRY templates via named templates | Helm chart best practices / named templates | ✗ F4 |
| One resource per template file, dashed names, kind-reflecting name | Helm best practices: `templates/` | ✓ |
| GPU pinning via CDI + `runtimeClassName` on a device-plugin-less k3s | NVIDIA CDI docs (runtime-class CDI mode is a supported path; device plugin + CDI is the managed-cluster default) | ✓ for this topology |
| `__structuredAttrs` + `strictDeps` for CUDA derivations | nixpkgs CUDA section | ✗ F12 |
| `fetchFromGitHub` with pinned rev + hash | nixpkgs convention | ✓ |
| `python3.withPackages` instead of a venv of symlinks (store-portable) | nixpkgs convention | ✓ and the comment explains why |
| GC root for a store path mounted into a pod | nix GC-roots docs (`/nix/var/nix/gcroots` symlinks) | ✓ mechanism, F7 lifetime |
| Pin image tags/digests | repo's own `docs/cluster-overview.md:127` | ✗ F11 |
| CI renders the chart on chart changes | `.github/workflows/k8s-manifest-diff.yml` | ✓ k8s/** only; nix/** untested (F8) |
| Secrets via sops → Secret, never values | `.sops.yaml`, `nix/services/k3s.nix` | ✓ API key from `litellm-keys/pod-api-key` |
