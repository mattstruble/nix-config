# Mjolnir — LLM Serving Cluster

NixOS GPU host serving two Qwen models concurrently via llama.cpp, optimized for
agentic coding and multi-user dispatch workloads on Turing-era hardware.

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

## Serving configuration

Two Docker containers, one model per GPU, managed via NixOS
`virtualisation.oci-containers` in `modules/hosts/mjolnir/default.nix`.

### GPU 0 — Qwen3.8-27B (coding / agentic)

| Setting | Value |
|---------|-------|
| Engine | llama.cpp (`ghcr.io/ggml-org/llama.cpp:server-cuda`) |
| Model | Unsloth UD-Q4_K_XL GGUF (4-bit, 17.6 GB) |
| Context | 131,072 tokens (128k) |
| KV cache | q8_0 |
| MTP | `--spec-type draft-mtp --spec-draft-n-max 2` |
| Flash attention | on |
| Decode slots | 1 (`-np 1`, single-user) |
| Reasoning | `reasoning_effort=medium`, budget 8192 |
| Chat template | Vendored (`qwen3-chat-template.jinja`) |

### GPU 1 — Qwen3.6-35B-A3B MoE (dispatch / chat / HA / n8n)

| Setting | Value |
|---------|-------|
| Engine | llama.cpp (same image) |
| Model | Unsloth UD-IQ4_XS GGUF from `-MTP` repo (4-bit, 18.2 GB) |
| Context | 262,144 tokens (256k) |
| KV cache | q5_1 |
| MTP | `--spec-type draft-mtp --spec-draft-n-max 2` |
| Flash attention | on |
| Decode slots | 2 (`-np 2`, 2 concurrent users, 128k per slot) |
| Reasoning | `reasoning_effort=medium`, budget 8192 |
| Chat template | Vendored (same as GPU 0) |

### Shared settings

- `GGML_CUDA_DISABLE_GRAPHS=1` — prevents CUDA graph caching deadlocks during
  long agentic sessions (Qwen aggressively caches checkpoints)
- Full GPU offload (`-ngl 99`) on both models
- Tool calling via vendored chat template (coalesces multiple system messages,
  handles `reasoning_effort` levels, preserves `<think>` blocks)
- API key: `foo` on both endpoints

### Endpoints

| Port | Model | Role |
|------|-------|------|
| 8556 | Qwen3.8-27B | Coding, agentic workflows |
| 8555 | Qwen3.6-35B-A3B | Chat, dispatch, HA intents, n8n |

## Throughput

### Single-user (warm)

| Model | Decode | Prefill (51k prompt) | MTP acceptance |
|-------|--------|---------------------|----------------|
| Qwen3.8-27B | 40 tok/s | 517 tok/s | 65% |
| Qwen3.6-35B-A3B | 121 tok/s | ~520 tok/s | 76% |

### Two concurrent users (3.6 only, `-np 2`)

| Model | Decode (per user) | Context per user |
|-------|-------------------|-----------------|
| Qwen3.6-35B-A3B | 22.5 tok/s | 128k |

Single-user on 3.6 gets full 121 tok/s — the second slot idles. The 22.5
tok/s per-user figure applies only when both users generate simultaneously.

### Cold start

~55s per container (model load + kernel init). One-time per restart; containers
stay up continuously.

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

### Flash attention on 3.6 concurrent decode

Flash-attn dropped 3.6's 2-user concurrent decode from 35+35 to 22.5+22.5 tok/s
(-36%). However, without flash-attn, prefill of a 51k-token prompt takes >5
minutes (O(n²) attention without flash-attn). With flash-attn, prefill is ~100s.
The prefill time dominates total request time for long prompts, so flash-attn is
net-positive despite the concurrent decode hit.

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

- **Flake host:** `modules/hosts/mjolnir/` in nix-config
- **Deploy:** `just deploy mjolnir` (deploy-rs, magic rollback disabled)
- **Model storage:** `/var/lib/llama-models/` (GGUF files)
- **NVIDIA driver:** initrd kernel module loading + nouveau blacklisted
- **Docker GPU passthrough:** CDI device syntax (`nvidia.com/gpu=0`, not `--gpus all`)
