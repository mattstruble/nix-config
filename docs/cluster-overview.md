# Mjolnir — LLM Serving Cluster

NixOS GPU host serving the LLM fleet as k3s pods behind one LiteLLM gateway
(`http://mjolnir:8000/v1`), optimized for agentic coding and voice workloads on
Turing-era hardware. The docker serving layer was retired 2026-09-20 (b595279);
the sections below the throughput tables are the historical docker-era record.

## Hardware

| Component | Value |
|-----------|-------|
| OS | NixOS unstable (26.11), managed by deploy-rs |
| CPU | AMD Ryzen Threadripper 3970X — 64 threads @ 3.7 GHz |
| RAM | 96 GB |
| GPU 0 | NVIDIA TITAN RTX — 24 GB VRAM, Turing sm_7.5 |
| GPU 1 | NVIDIA TITAN RTX — 24 GB VRAM, Turing sm_7.5 |
| GPU interconnect | NVLink (2 bonded links, ~100 GB/s) |
| Storage | 1.8 TB NVMe |

## Serving configuration (current — k3s, since 2026-09-17)

One k3s cluster (`nix/services/k3s.nix`), one values file per model from the
helm chart in `k8s/apps/ai/` (`just k8s-render` previews, `just deploy mjolnir`
ships host + cluster in one generation). Two lifecycles: **static** models render a
Deployment that is always up (none today), **on-demand** models
(`lifecycle: on-demand`) render no Deployment at all — the swap head-end
creates one on request, waits for readiness, proxies, and scales it back to
zero on idle (see the on-demand fleet section below). Since 2026-10-12 the
whole fleet, flash-next included, is on-demand: idle hands back both cards
(~87 GiB host RAM free, measured) and every model wakes on request. All clients (pi,
opencode, HA, n8n) hit the LiteLLM gateway at `:8000` and name the model in the
request — model ID = real running name (`--alias` = gateway `model_name`, no
masking). Models PV = `/var/lib/llama-models` (local PV, PSS-restricted);
`nixBinary: true` models also mount `/nix/store:ro`.

### GPU 0 — swift-qwen3.8-27b (coding / agentic, on-demand since 2026-10-12)

Swift-Qwen3.8-27B (gated Swift Open v1.0 license; GGUF hand-pulled, not
flake-reproducible). b10920 upstream image (digest pinned), `--reasoning` baked
into the vendored template at `xhigh` — not per-request.

| Setting | Value |
|---------|-------|
| Model | `Swift-Qwen3.8-27B-Q4_K_M.gguf` (18 GB; ssm_out/attn_gate/output/token_embd lifted to Q6_K) |
| Context | 131,072 tokens, `-ub 1024` |
| KV cache | q8_0 K + q8_0 V |
| MTP | `draft-mtp`, n-max 2, n-min 1 (head embedded in the GGUF at Q8_0) |
| Flash attention | on |
| Sampling | temp 0.6, top-k 20, top-p 0.8, repeat-penalty 1.0 (Qwen coding preset) |
| Chat template | vendored `qwen3-chat-template.jinja` (chart configmap) |

### GPU 1 — flash-next-strata-iq4xs (general / tools, on-demand since 2026-10-12)

Qwen3.8-Flash-Next on the **Strata engine** (Niko1221/Strata, MIT) — a Python
server driving a compiled C++ engine, not llama.cpp. Gateway name
`qwen3.8-flash-next`, unchanged from the retired llama.cpp fork, so no client
moved. Built natively for sm_75 by `nix/hosts/mjolnir/_strata.nix`.

| Setting | Value |
|---------|-------|
| Model | `Qwen3.8-Flash-Next-UD-IQ4_XS` (largest quant that fits the fleet: 24 GB RAM headroom) |
| Context | 262,144 tokens |
| KV cache | int8, 32,768 resident |
| Speculative | `--spec 4`, `--spec-min-p 0.5`, MTP `rt` |
| Experts | from the pack, 55 GiB resident (`--resident-budget-gib`; this is what `LOW_RAM=on` resolves to) |
| Decode / prefill | 32–57 t/s, ~1030 t/s prefill (2026-10-07 bench) |

**On-demand since 2026-10-12:** both gemma endpoints (the thinking variant and
the non-thinking one — same weights, reasoning on/off is the only difference)
and swift-qwen3-8-27b share the swappable slot — one model awake at a time, the
waker evicts the other automatically. All render no static Deployment; their
pod specs travel to the head-end and the models wake on request — flash-next
included since 2026-10-12, with a 1800 s ttl: it stays resident through the
work day and sleeps overnight, handing GPU 1 back as a second swappable slot.
Gemma's config and pack were already on the PVC; nothing was migrated.

### The on-demand fleet — wake times and model names (measured 2026-10-12)

The swapper is llama-swap v264 plus this repo's `swapk8s` shim
(`nix/hosts/mjolnir/_swapk8s.nix`, one store path linked through the render
the same way the strata bundle is). Clients still name the model at `:8000`
exactly as before — the names below are unchanged — but the gateway routes
on-demand models to the head-end, which holds the request, streams loading
remarks into the reasoning field, and answers when the model is up.

| Model — what clients name | Deployment / roster key | Wake, cache-warm | Wake, cache-cold | Idle sleep |
|---|---|---|---|---|
| `swift-qwen3.8-27b` | `swift-qwen3-8-27b` | 100–111 s | 100 s (60 s pod-to-Ready) | ttl 900 s |
| `gemma-4-26b-a4b` (non-thinking) | `gemma-4-26b-a4b` | 126 s | — same weights as the think variant: 144 s | ttl 900 s |
| `Qwen3.6-35B-A3B` | `qwen3-6-35b-iq4xs` | 96.7 s (first on-demand wake, placed on gpu 0) | — same loader shape as gemma | ttl 900 s |
| `gemma-4-26b-a4b-think` | `gemma-4-26b-a4b-think` | 126–137 s (137 s through a full eviction) | 144 s (80 s pod-to-Ready) | ttl 900 s |
| `qwen3.8-flash-next` | `flash-next-strata-iq4xs` | 86 s (first on-demand wake; the restart-wake it replaced measured 83 s) | — | **ttl 1800 s** — the coding agent never pays a wake during the work day; it sleeps overnight and hands the card back |

Cold wakes were measured with the page cache dropped before the request
(`echo 3 > /proc/sys/vm/drop_caches`). The result kills a piece of lore: the
wakes land in the same band warm (~100–144 s), so the load is compute-bound,
not disk-bound — the "23 minutes of weight loading" the swift entry used to
carry never survived a measurement, and could not have: the pod's own
startupProbe budget is 30×10 s = 300 s, so a 23-minute load would have
failed the probe before anything else gave up. `coldStartSeconds` therefore
sits at 240 s — comfortably above the measured load, and within the probe
budget, which is the real ceiling: a budget larger than the probe's means the
pod fails and restarts before the shim ever gives up on it. A warm request
through the head-end costs ~0.1 s to first token — the swapper on the path is
free. Both cards can be loaded at once with ~37–39 GiB host RAM still free;
the swapper runs one group per card (`exclusive: false`), so one model per
card awake at a time and two models in tandem across the cards — measured
with two wakes fired 15 s apart: both served, both Ready simultaneously, host
RAM never below 38.5 GiB. Within a card, waking a model evicts the card-mate.
A head-end restart puts the whole fleet to sleep.

**Dynamic placement (2026-10-12, night, verified live): models are not pinned
to cards.**
A model's `gpu:` value in its values entry is its card **pool** ("0,1"), and
the shim lands every wake on a free card from the pool: it scans model pods
for held cards, takes a free one under a placement lock (flock — the race it
closes is two wakes seeing the same free card), applies the spec with the
chosen card in `NVIDIA_VISIBLE_DEVICES`, and holds the lock until the pod
exists so the next wake's scan sees the claim. When every card is busy the
wake **waits** (`headEnd.cardWaitSeconds`, 300 s) rather than crashlooping a
pod onto a busy card — the failure mode that produced the first cutover's
crashloop — and fails with a reason if the wait runs out. A one-card pool is
still a pin, so a model can be restricted deliberately. A model that needs
**every** card (`gpuMode: all`, e.g. the future 2-GPU strata variant) gets
its own `exclusive: true` group: waking it unloads the fleet, and a
single-card wake onto a card it holds is the shim's wait, which is why
placement lives in the shim rather than the group router (the router is
static topology, not resource awareness). The group structure collapsed
with placement: one `anywhere` group, `swap: false` — coexistence is the
shim's to arbitrate now.

Measured live: two wakes ten seconds apart landed on opposite cards (the pod
env values prove the shim decided — the values files carry pools, not pins),
both Ready simultaneously, answers at t+94.6 s and t+138.7 s. A wake into a
fully busy fleet created **no pod at all** — it held the request for the
whole 300 s card-wait with the loading stream open, then gave up with the
start failure in-band. The pool/mode labels the chart renders on the spec
are a transport channel the shim consumes and strips — a pool like "0,1" is
an invalid *label value* (kubernetes rejects commas), which the first live
apply caught as a 422.

**The 2-GPU spanning variant (2026-10-12): built, benchmarked, honestly gated
off.** A real setup pass minted its config (`gpu [0,1]`, `layer_split auto`,
`--remote-expert-opt`, 262144 context with the KV cache streamed to RAM), the
span machinery was verified live — an exclusive `span-0-1` group that unloads
the fleet on wake, one pod claiming both cards — and the benchmark gate closed
it: the multi-GPU load path is a single-threaded CPU phase whose host RSS
climbs past 60 GB toward the setup's own ~118 GB worst-case estimate and dies
before serving, restarting into the same cycle. On a 94 GiB host it does not
fit; the entry is `enable: false` with the full working setup recorded in
values — on a 128 GiB host, re-enable it as-is.

The gemma endpoints — **both on-demand since 2026-10-12** — are the same
weights sharing the one swappable slot, so the exclusive group swaps them
like any two models: waking either evicts the other, and a measured
variant-to-variant swap (think requested while non-think was loaded) took
142.6 s end to end. Pick by name: the **thinking** variant for deliberating
agents (reasoning is an endpoint property, not a request property — it is
binary at the sampler and no per-request knob reaches it), the non-thinking
variant for voice/classification traffic that needs speakable latency and
fixed-budget JSON. A thinking model spends its first tokens on reasoning, so
a small `max_tokens` can end the stream before any content: the 144 s cold
wake above reached its first *content* token at the end of the load; budget
content accordingly.

### The `engine: strata` recipe

A strata model is rendered by `templates/strata-deployment.yaml`, not
`model-deployment.yaml`. Four things make one up, and each lives somewhere
different:

1. **The engine** — `nix/hosts/mjolnir/_strata.nix` builds engine + server +
   venv as one read-only bundle. `binary:` in the values file pins its
   `/nix/store` path; `nix/hosts/mjolnir/default.nix` keeps that path a GC root
   and parks the previous one on `-prev` so a rollback has something to build
   from. CI fails if the pin drifts from what the config builds.
2. **Engine settings** — `.strataConfig` in the values file, rendered into a
   ConfigMap and mounted over `/data/config/strata-<tag>.json`. It is the
   recorded output of one `setup.py --setup` pass; `@BUNDLE@` inside it expands
   to `.binary` so a bundle bump moves `exe`/`cwd`/`--expert-profile` with it.
   `api_key` is empty on purpose: the key comes from the `litellm-keys` Secret
   and the entrypoint passes it as `--api-key`.
3. **Model + pack + MTP** — on the models PVC under `/data`, pre-populated so
   the entrypoint skips the ~90 GB download.
4. **The ENV surface** — `FAMILY`/`MODEL` pick the config file (for
   `family: qwen` the tag has **no** `qwen-` prefix: `strata-ud-iq4_xs.json`),
   `GPU`/`PORT`/`API_KEY` are forwarded as CLI flags. `gpuIndex` is
   **container-local**, not the host index: the CDI pin exposes only the pinned
   card, so it is always `0` inside the container.

Rollouts are `Recreate` (the model owns its card) and there is no livenessProbe
— it would kill a pod mid-generation. A 262k-token prefill (~255 s) exceeds the
120 s termination grace, so a rollout during one does interrupt it.

### Dormant chart models (enable: false)
gemma-4-26b-a4b (non-thinking), gemma-4-26b-a4b-think (same weights, reasoning
left on — thinking is an endpoint property, so voice and deliberating agents
cannot share a server), qwen3-6-35b-iq4xs. All are image-based; none needs a
nix-built binary. All declare `gpu: "0"` — GPU 1 belongs to the resident
orchestrator, so there is exactly one swappable slot. The 35B's pinned image
(`41ebf873c2e0`) is not in containerd, so its first wake needs a pull.

Retired 2026-10-12 also: gemma-4-26b-a4b-longctx (262k, non-thinking) — redundant
with the 262k orchestrator, and long-context recall was never its strength.
Retired earlier: qwen3-8-flash-next (+256k) and qwen3-8-27b (+turboq) — the
four `nixBinary: true` entries that pointed at the nix-built llama.cpp forks.
Their pinned store paths had already been garbage-collected, so a wake would
have crashed; deleting them also freed `_llama-fork.nix` and
`_llama-turboq.nix`, which nothing else referenced. The Strata bundle is now the
only nix-built thing a pod mounts.

### Endpoints (current)

| Endpoint | Model ID | Role |
|----------|----------|------|
| `http://mjolnir:8000/v1` | `swift-qwen3.8-27b` | Coding, agentic workflows (GPU0) |
| `http://mjolnir:8000/v1` | `qwen3.8-flash-next` | General, tools, long context (GPU1) |

Pod-internal ports (8556/8555) are not published; only the gateway hostPort
8000 is. Historical docker endpoints: 8556 = flash-next/27B, 8555 = 3.6/27B/gemma.

## Historical: docker-era fleet (through 2026-09-17)

Two Docker containers, one model per GPU, managed via NixOS
`virtualisation.oci-containers` (deleted 2026-09-20).

### GPU 0 — Qwen3.8-Flash-Next (coding / agentic)

125B-class hybrid-SSM MoE. Replaced Qwen3.8-27B on 2026-09-01: 125B-class
quality + 256k context outweigh the 2× decode slowdown (20 vs 40 tok/s).
Requires the mjungnickel18 llama.cpp fork (upstream can't run this model's
MTP + MoE expert residency) — built from source by nix
(`nix/hosts/mjolnir/_llama-fork.nix`: rev + hash pinned; bump = update both).

| Setting | Value |
|---------|-------|
| Engine | llama.cpp fork `qwen4exp-mtp-plus-moe-residency` @ 0384f5c, built by nix for sm_75 (cudaPackages, nvcc 12.9); container runs it from `/nix/store` mounted `:ro` on a digest-pinned CUDA 12.6 base — CDI `--device` mandatory (nix binaries link `libcuda.so.1` directly) |
| Model | Unsloth UD-Q3_K_XL GGUF, MoE experts split hot/cold (92 GB; hot64 in VRAM, cold on CPU via `-ot "exps_cold=CPU"`) |
| MTP sidecar | `mtp-fn-jockeupptaget-Q8_0.gguf` (4.1 GB; jockeupptaget layout — fused-`eh_proj` sidecars are incompatible) |
| Context | 131,072 tokens, `-ub 1024` (256k mode: no MTP, `-c 262144 -ub 256` — see comment) |
| KV cache | q8_0 |
| MTP | `--spec-type draft-mtp --spec-draft-n-max 6 --spec-draft-p-min 0.75` |
| Flash attention | on (hard requirement — q8_0 KV needs it, f16 KV OOMs) |
| Decode slots | 1 (`-np 1`, single-user) |
| Reasoning | budget 8192 (built-in `--jinja` template) |
| Chat template | Built-in (`--jinja`, validated incl. tool calling) |

### GPU 1 — Qwen3.8-27B dense (dispatch / chat / HA / n8n)

| Setting | Value |
|---------|-------|
| Engine | llama.cpp (image digest pinned, see below) |
| Model | Unsloth UD-Q4_K_XL GGUF (4-bit, 17.6 GB) |
| Context | 131,072 tokens (128k) |
| KV cache | q8_0 K + q8_0 V |
| MTP | `draft-mtp`, n-max 2, n-min 1 |
| Flash attention | on |
| Ubatch | 256 |
| Decode slots | 1 (`-np 1`) |
| Reasoning | `reasoning_effort=medium`, budget 8192 |
| Chat template | Vendored (same as GPU 0) |

Took over GPU 1 from Qwen3.6-35B-A3B on 2026-09-04. Its 256k context and
`-np 2` are what 3.6 traded for: 27B runs 128k single-slot with MTP.
Not benched on this swap — the throughput table below has no 27B row, so don't
quote it for GPU 1.

### Shared settings

- `GGML_CUDA_DISABLE_GRAPHS=1` — prevents CUDA graph caching deadlocks during
  long agentic sessions (Qwen aggressively caches checkpoints)
- 3.6 image digest pinned (`@sha256:41ebf873c2e0…`, build 2026-08-24). The
  floating `server-cuda` tag changed flash-attn behavior on the hybrid-SSM
  model between 2026-08-25 and 08-26 — never run 3.6 on an unpinned tag.
- `--cache-reuse` is **not supported** for the 3.6's hybrid SSM context in
  this build (server logs `cache_reuse is not supported by this context`).
  Slot-level prefix reuse still works natively: a repeated prompt returns
  `cached_tokens` ≈ 100% of the prompt, so conversation turns 2+ skip
  re-prefill without any flag.
- Full GPU offload (`-ngl 99`) on both models
- Tool calling via vendored chat template (coalesces multiple system messages,
  handles `reasoning_effort` levels, preserves `think` blocks)
- API key: `foo` on both endpoints

## Throughput

### Single-user (warm)

| Model | Decode | Prefill | MTP acceptance |
|-------|--------|---------|----------------|
| Qwen3.8-Flash-Next | 20.2/18.7/20.6 tok/s @4k/15k/51k, 19.5 @122k depth (flat — hybrid SSM); 11 tok/s @257k in 256k mode | 142 tok/s (`-ub 1024`, fastest that fits 24GB; ~65s for a 15k first prompt, turns 2+ skip re-prefill); 54 in 256k mode | 0.87–0.98 (mean draft len 4.1–5.6) |
| Qwen3.6-35B-A3B (dormant since 2026-09-04) | 80 tok/s @15k ctx, 66 @24k, 51 @43k | ~1250 tok/s @15–28k, 951 @91k (51k ≈ 54s) | — (removed) |

3.6 decode degrades gently with context (hybrid SSM — most layers are linear
attention). Short-context decode is ~102 tok/s without MTP (was 121 with MTP).

### Two concurrent users (3.6 only, `-np 2` — 3.6 dormant, kept for reference)

128k context per slot. With long prompts, the two prefills interleave
(~41s each for a 24.5k prompt); a user mid-decode drops to ~3 tok/s while the
other's prefill runs, then recovers to ~44–66 tok/s. Far better than the old
FA-on config, where each 24.5k prefill took ~28 minutes.

### Cold start

~55s per container (model load + kernel init). One-time per restart; containers
stay up continuously.

Additionally, the **first request** after a restart (or long idle) carries a
28–48s penalty on top of normal prefill (measured 50s TTFT vs 11.5s warm for a
15k prompt, 2026-08-27). Not FA- or CUDA-graph-related. If it becomes a
problem, a systemd timer sending a periodic 1-token completion keeps the
server warm — note the image's built-in healthcheck probes port 8080 (wrong
port), so nothing pings the server today and `docker ps` shows "unhealthy"
permanently.

## What was tested and rejected

### vLLM (all variants)

Tested vLLM as an alternative backend across multiple configurations. All
rejected — structurally slower than llama.cpp on Turing.

| Config | Decode | Notes |
|--------|--------|-------|
| AWQ-INT4 TP1 | 15.5 tok/s | MTP proposer crash (Marlin repack OOM) |
| FP8 TP2 + MTP | 13.3 tok/s | MTP survived, but FP8 dequants to FP16 on Turing = 2× bandwidth |
| AWQ-INT4 TP2 + MTP n=2 | 27.5 tok/s | Best vLLM result, still 36% below llama.cpp fleet |

**Why vLLM loses on Turing:** eager-mode per-step overhead (CUDAGraph OOMs at
0.95 util on 24 GB, no batching to amortize at batch=1), TP2 allreduce overhead,
and vLLM's Marlin kernel less hand-tuned for sm_7.5 than llama.cpp's Q4 kernels.

### Flash attention on 3.8 at short context

At 16k context, flash-attn dropped MTP acceptance from 91% to 68% with no speed
gain — attention is a tiny fraction of decode cost at short context (weight
loading dominates). Revisited at 128k context: flash-attn gave +32% decode and
+61% prefill, making it a clear win for long-context agentic use. The breakpoint
is context length, not a blanket on/off.

### Flash attention on 3.6 (pinned build)

In the pinned image (build 2026-08-24), flash-attn is **broken** for the
hybrid-SSM 3.6: 51k prefill at 14.6 tok/s (36 min) with FA on vs 951 tok/s
with FA off. An earlier 2026-08-25 measurement on the floating tag showed FA
helping (520 tok/s) — the tag moved between measurements, which is why the
digest is now pinned. FA stays off; re-test on any future pinned build.

### KV cache quantization below q5_1

Tested q4_0 KV on 3.8 to fit 256k context in 24 GB. Speed and MTP acceptance
were unaffected, but a controlled quality test (retrieving specific class names
from 5k tokens back in context) showed q4_0 produced zero output (all 2048
tokens spent on reasoning, instruction lost) while q8_0 retrieved 11/14 exact
names and produced correct code. q4_0 KV is not suitable for coding workloads.

### MTP n-max > 2

Tested `--spec-draft-n-max 3` on both models. Acceptance drops (78% → 64% on
3.6) offsetting the extra draft tokens — no net speed gain. n-max 2 is the
sweet spot.

## Turing constraints (sm_7.5)

These hard limits shaped every decision:

| Constraint | Impact |
|-----------|--------|
| No BF16 (needs SM80+) | KV cache must be fp16, not bf16 |
| No FlashAttention 2 (needs compute ≥ 8.0) | llama.cpp's own flash-attn used instead |
| No native FP8 compute | FP8 dequants to FP16 = 2× bandwidth of 4-bit |
| CUDAGraph capture OOM at 0.95 util | `--enforce-eager` required for vLLM; `GGML_CUDA_DISABLE_GRAPHS=1` for llama.cpp |
| No FlashInfer sampling | Fallback sampler |

## Management

- **Flake host:** `nix/hosts/mjolnir/` in nix-config
- **Deploy:** `just deploy mjolnir` (deploy-rs, magic rollback disabled)
- **Kernel/NVIDIA driver bumps:** cannot activate in place — use `nix run .#deploy-rs -- --boot .#mjolnir` then `ssh mjolnir 'sudo reboot'`. In-place `nixos-rebuild switch` leaves the old kernel module loaded, CDI generator hits 'Driver/library version mismatch', and containers exit 125 with auto-rollback.
- **Model storage:** `/var/lib/llama-models/` (GGUF files)
- **Which model runs where:** the helm chart in `k8s/apps/ai/` — one
  values file per model (`enable`, `gpu`, `port`, flags), rendered and applied
  by `just k8s-deploy`. A swap edits the values files; the pod restarts and
  the model reloads from page cache (~90s).
- **New files must be `git add`ed before deploying:** deploy-rs runs
  `nix flake check`, which evaluates the git tree and skips untracked files —
  a brand-new module reads as "undefined variable" until staged.
- **NVIDIA driver:** initrd kernel module loading + nouveau blacklisted
- **Docker GPU passthrough:** CDI device syntax (`nvidia.com/gpu=0`, not `--gpus all`)
