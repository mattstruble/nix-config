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

One k3s cluster (`nix/services/k3s.nix`), one Deployment per model from the
helm chart in `k8s/apps/ai/` (one values file per model; `just k8s-deploy`
renders + applies). All clients (pi, opencode, HA, n8n) hit the LiteLLM gateway
at `:8000` and name the model in the request — model ID = real running name
(`--alias` = gateway `model_name`, no masking). Models PV = `/var/lib/llama-models`
(local PV, PSS-restricted); `nixBinary: true` models also mount `/nix/store:ro`
and run the nix-built fork binary (store path hardcoded in the values file).

### GPU 0 — swift-qwen3.8-27b (coding / agentic)

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

### GPU 1 — gemma-4-26b-a4b (voice / HA / n8n)

Gemma 4 26B-A4B, `--reasoning off` (voice: 0.06s speakable TTFT; reasoning is
binary on this build and `low` is 40–200× too slow — see the gemma note).

| Setting | Value |
|---------|-------|
| Model | `gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf` + MTP drafter `mtp-gemma-4-26B-A4B-it-Q8_0.gguf` |
| Context | 131,072 tokens, `-ub 2048` |
| KV cache | q8_0 K + q8_0 V |
| MTP | `draft-mtp`, n-max 2, p-min 0.75 |
| Flash attention | on |
| Reasoning | **off** (server-level; per-request `reasoning_effort` is a no-op) |

### Dormant chart models (enable: false)
qwen3-8-flash-next (+256k), qwen3-8-27b (+turboq), qwen3-6-35b-iq4xs,
gemma-4-26b-a4b-longctx. The four `nixBinary: true` ones need the nix-built
forks (`_llama-fork.nix`, `_llama-turboq.nix` — kept after the docker-layer
deletion because their store paths are hardcoded in the chart values).

### Endpoints (current)

| Endpoint | Model ID | Role |
|----------|----------|------|
| `http://mjolnir:8000/v1` | `swift-qwen3.8-27b` | Coding, agentic workflows (GPU0) |
| `http://mjolnir:8000/v1` | `gemma-4-26b-a4b` | Voice, HA intents, n8n (GPU1) |

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
