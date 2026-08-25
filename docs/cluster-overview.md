# Mjolnir Cluster Overview

Mjolnir is the GPU compute host for the homelab. This document covers hardware,
the current model serving fleet, what was tried and rejected, and the Turing
constraints that shaped every decision.

## Hardware

| Component | Value |
|-----------|-------|
| OS | NixOS unstable (26.11), managed by deploy-rs |
| CPU | AMD Ryzen Threadripper 3970X — 64 threads @ 3.7GHz |
| RAM | 96GB |
| GPU 0 | NVIDIA TITAN RTX — 24GB VRAM, Turing sm_7.5 |
| GPU 1 | NVIDIA TITAN RTX — 24GB VRAM, Turing sm_7.5 |
| GPU interconnect | NV2 NVLink (2 bonded NVLinks, ~100 GB/s aggregate) |
| Storage | 1.8TB NVMe |
| Network | Bonded dual 1GbE (LACP) + Tailscale |

Both GPUs have a physical NVLink bridge. `nvidia-smi topo -m` shows `NV2` in
the GPU0-GPU1 cell. The link is active and used by NCCL allreduce under vLLM
tensor parallelism, but idle under the current llama.cpp fleet (one model per
GPU, no cross-GPU comms).

## Current model fleet

Two containers, one per GPU, managed via NixOS `virtualisation.oci-containers`
in `modules/hosts/mjolnir/default.nix`.

### GPU 0 — Qwen3.8-27B (primary, coding/agentic)

| Setting | Value |
|---------|-------|
| Engine | llama.cpp (Docker, `ghcr.io/ggml-org/llama.cpp:server-cuda`) |
| Model | `Qwen3.8-27B-UD-Q4_K_XL` (Unsloth GGUF, 4-bit, 17.56 GB) |
| Offload | Full (`-ngl 99`) |
| Context | 16384 tokens |
| KV cache | q8_0 (both K and V) |
| MTP | `--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-n-min 1` |
| Speed | **43 tok/s** single-stream (warm), 91% MTP acceptance |
| Prefill | 55.6 tok/s (warm) |
| Cold start | ~45s (model load) |
| VRAM | 17.5 GiB |
| Port | 8556 (api-key: `foo`) |
| Reasoning | `reasoning_effort=medium` + `--reasoning-budget 8192` |
| Chat template | Vendored (`modules/hosts/mjolnir/qwen3-chat-template.jinja`) |
| Tool calls | OpenAI-compatible `tool_calls` format |

### GPU 1 — Qwen3.6-35B-A3B MoE (fast dispatch / chat / HA / n8n)

| Setting | Value |
|---------|-------|
| Engine | llama.cpp (Docker, same image) |
| Model | `Qwen3.6-35B-A3B-UD-Q4_K_XL` (Unsloth GGUF, MoE 3B active) |
| Offload | 40/64 layers on GPU, 24 offloaded to CPU (96 GB RAM absorbs) |
| MTP | `--spec-type draft-mtp` |
| Speed | **~74 tok/s**, 80% MTP acceptance |
| VRAM | 22.4 GiB |
| Port | 8555 (api-key: `foo`) |

### 2-user concurrent performance

Each user hits a different GPU — no contention, no queueing:

| | Unified TP2 (rejected) | Fleet (deployed) |
|---|---|---|
| User 1 | 16.1 tok/s | 43 tok/s |
| User 2 | 17.3 tok/s | 74 tok/s |

The fleet's two-GPU true parallelism is the decisive win for multi-user.

## What we tried and rejected

Every backend/quant/TP combination tested on this hardware, with hard numbers.

| # | Config | Speed (single) | MTP | Tool calls | Status |
|---|--------|---------------|-----|------------|--------|
| 1 | vLLM AWQ-INT4 TP1 (Twu31) | ~15.5 tok/s | Crashed | Broken | Replaced |
| 2 | vLLM AWQ-INT4 TP1 + flags + template | ~15 tok/s | Crashed | Working | Replaced |
| 3 | vLLM FP8 TP2 + MTP(n=1) | 13.3 tok/s | Worked | Working | Rejected |
| 4 | vLLM AWQ-INT4 TP2 + MTP(n=1) | 21.6 tok/s | Worked | Working | Baseline |
| 5 | vLLM AWQ-INT4 TP2 tuned + MTP(n=2) | 27.5 tok/s | Worked | Working | Rejected |
| 6 | **llama.cpp Q4_K_XL + MTP** | **43 tok/s** | **Worked** | **Working** | **Deployed** |

### 1. vLLM AWQ-INT4 TP1 — Twu31 model (original)

- **Config:** `Twu31/Qwen3.8-27B-AWQ-INT4-MTP-LowLatency`, TP1, fp16 KV, 32k
  ctx, 0.95 util, enforce-eager
- **Speed:** ~15.5 tok/s
- **MTP crash:** `gptq_marlin_repack` → `aten::empty` OOM in
  `llm_base_proposer.load_model`. The MTP proposer repacks AWQ-INT4 weights to
  Marlin format, and the allocation fails — 0.95 util on one 24 GB card leaves
  no headroom for the proposer's weight processing.
- **Tool calling:** Broken — missing `--enable-auto-tool-choice` and
  `--tool-call-parser` flags. opencode sends `tool_choice: "auto"` and vLLM
  rejects it.
- **Why rejected:** MTP unusable, tool calling broken, slow.

### 2. vLLM AWQ-INT4 TP1 + tool-calling flags + chat template

- **Added:** `--enable-auto-tool-choice`, `--tool-call-parser qwen3_xml`,
  `--reasoning-parser qwen3`, `--enable-prefix-caching`, vendored chat
  template via `--chat-template`
- **Result:** All flags accepted by vLLM 0.27.1. Tool calls parse correctly.
  MTP still crashes (same Marlin repack OOM).
- **Why rejected:** Functionally working but ~15 tok/s with no MTP — llama.cpp
  + MTP at 43 tok/s is 2.9× faster.

### 3. vLLM FP8 TP2 + MTP(n=1) — official Qwen FP8

- **Config:** `Qwen/Qwen3.8-27B-FP8`, TP2 over NVLink, enforce-eager,
  `--speculative-config '{"method":"mtp","num_speculative_tokens":1}'`
- **MTP survived** — FP8 uses a different quantization kernel (no Marlin
  repack path). The Twu31 crash was AWQ-Marlin-specific, not fundamental to
  vLLM + MTP + TP2.
- **Speed:** 13.3 tok/s single-stream, 10.2 + 4.6 tok/s 2-concurrent
- **KV cache:** 2.94 GiB, 74k tokens, 2.26× concurrency at 32k
- **Cold start:** ~6 min (253s Triton JIT warmup on Turing)
- **Why rejected:** FP8 dequants to FP16 on Turing (no FP8 tensor cores on
  sm_7.5) = 2× memory bandwidth of 4-bit. Structurally slow for decode.
  13.3 tok/s is 3.2× slower than the fleet.

### 4. vLLM AWQ-INT4 TP2 + MTP(n=1) — cyankiwi model

- **Config:** `cyankiwi/Qwen3.8-27B-AWQ-INT4`, TP2, enforce-eager, MTP n=1
- **Marlin confirmed on Turing:**
  `compressed_tensors_wNa16: Using MarlinLinearKernel` (both workers)
- **MTP proposer did not crash** — cyankiwi *shares* target model
  embedding/lm_head weights with the draft model (no Marlin repack needed).
  This is why cyankiwi's model works where Twu31's didn't.
- **Speed:** 21.6 tok/s single-stream, 14.2 + 15.0 tok/s 2-concurrent
- **KV cache:** 7.79 GiB, 74k tokens, 2.26× concurrency

### 5. vLLM AWQ-INT4 TP2 tuned + MTP(n=2) — maximally tuned

- **Config:** Same model, TP2, enforce-eager, plus:
  - `--speculative-config '{"method":"mtp","num_speculative_tokens":2}'`
  - `--max-num-batched-tokens 8192` (vLLM flagged 2048 default as suboptimal
    for spec decode)
  - `--gpu-memory-utilization 0.95` (more KV headroom)
  - `--dtype float16` (avoid bf16 cast warning)
  - `VLLM_USE_FLASHINFER_SAMPLER=0` (silence Turing warning)
- **Speed:** 27.5 tok/s single-stream, 16.1 + 17.3 tok/s 2-concurrent
- **KV cache:** 8.72 GiB, 207k tokens, 6.34× concurrency
- **Cold start:** ~9 min (258s engine init)
- **Tuning gains over n=1:** +28% single-stream (21.6 → 27.5), 3× KV
  (74k → 207k)
- **Why rejected:** Still 36% below the fleet's 43 tok/s. The 2-user case is
  even more lopsided: 16+17 (shared-model time-slicing) vs the fleet's 43+74
  (each own GPU).

### 6. llama.cpp Q4_K_XL + MTP — deployed winner

- **Config:** Unsloth UD-Q4_K_XL GGUF, full offload, KV q8_0, draft-mtp
  n-max 2, vendored chat template, reasoning_effort=medium + budget 8192
- **Speed:** 43 tok/s single-stream (warm), 55.6 tok/s prefill, 91% MTP
  acceptance
- **Cold start:** ~45s
- **VRAM:** 17.5 GiB
- **Tool calls:** OpenAI-compatible `tool_calls` format
- **Why it wins:** llama.cpp's Q4 kernels (W4A16, in-register dequant) are
  better optimized for sm_7.5 than vLLM's Marlin path. No eager-mode per-step
  Python/kernel-launch overhead (batch=1 has no batching to amortize it). No
  TP2 allreduce penalty (single GPU, no cross-GPU comms).

## Why llama.cpp beats vLLM on Turing

The ~2× speed gap (43 vs 27.5 tok/s) is structural, not a tuning issue:

1. **Eager-mode per-step overhead.** Turing requires `--enforce-eager`
   (CUDAGraph capture OOMs at 0.95 util on 24 GB). In eager mode, every
   decode step incurs Python overhead and kernel-launch latency. At batch=1
   there's no batching to amortize this. llama.cpp has a tighter C++ decode
   loop with less per-step overhead.

2. **Kernel optimization.** llama.cpp's Q4 kernels (W4A16, in-register
   dequant) are highly tuned for sm_7.5 decode. vLLM's Marlin W4A16 kernel
   works on Turing but is less hand-tuned for this architecture.

3. **TP2 allreduce.** Under vLLM TP2, every layer requires an NCCL allreduce
   over NVLink (~5-13% overhead at batch=1). The fleet runs one model per GPU
   with zero cross-GPU communication.

4. **FP8 is wrong for Turing.** FP8 dequants to FP16 on sm_7.5 (no FP8 tensor
   cores) = 2× memory bandwidth of 4-bit. Decode is memory-bandwidth-bound.
   FP8 only makes sense on Ampere+ (SM80+) with native FP8 compute.

## MTP crash root cause

The MTP proposer crash that killed vLLM AWQ-INT4 was **model-specific, not
architecture-specific**:

- **Twu31 model:** proposer repacks AWQ-INT4 weights to Marlin format via
  `gptq_marlin_repack` → `aten::empty` allocation fails (OOM at 0.95 util,
  one GPU). Even at TP2 with more headroom, Twu31 would need the repack.
- **cyankiwi model:** proposer *shares* target model
  embedding/lm_head weights with the draft model — no repack needed, no OOM.
  This is why cyankiwi's AWQ-INT4 + MTP works on vLLM where Twu31's didn't.

Both models are AWQ-INT4, same quant class. The difference is how the MTP
proposer loads its weights. If using vLLM + AWQ-INT4 + MTP, use cyankiwi, not
Twu31.

## MTP speculative-config method string

The `--speculative-config` **method** for MTP is `"mtp"` (the vLLM factory maps
`method == "mtp"` → `MTPSpeculator`). The string `"qwen3_5_mtp"` is the
auto-detected *model_type/architecture*, not the method string. On upstream
nvidia vLLM, use `"mtp"`:

```json
{"method": "mtp", "num_speculative_tokens": 2}
```

## Turing constraints (sm_7.5 hard limits)

These shaped every config decision:

| Constraint | Impact |
|-----------|--------|
| No BF16 (needs SM80+) | KV cache must be fp16, not bf16 |
| No FlashAttention 2 (needs compute ≥ 8.0) | Falls back to TRITON_ATTN / xformers |
| No native FP8 compute (no FP8 tensor cores) | FP8 dequants to FP16 = 2× bandwidth of 4-bit |
| No SymmMem communicator (capability 7.5) | NCCL/PYNCCL fallback for allreduce (works over NVLink) |
| No FlashInfer sampling | Fallback sampler (`VLLM_USE_FLASHINFER_SAMPLER=0` to silence) |
| CUDAGraph capture OOM at 0.95 util on 24 GB | Must use `--enforce-eager` in vLLM |
| FP8 KV cache needs SM 8.9+ | Not available |

## Key config decisions

1. **llama.cpp over vLLM** — Q4 kernels better optimized for sm_7.5, no
   eager-mode per-step overhead, no TP2 allreduce penalty.
2. **Fleet over unified-TP2** — two-GPU true parallelism (43+74 tok/s for
   2 users) beats shared-model time-slicing (16+17 tok/s).
3. **AWQ-INT4 Marlin crash** — model-specific (Twu31 repacks → OOM; cyankiwi
   shares weights → no repack). Use cyankiwi for vLLM + AWQ-INT4 + MTP.
4. **MTP method string** — `"mtp"` (upstream factory), not `"qwen3_5_mtp"`
   (that's the model_type).
5. **Reasoning effort medium** — 3.8 defaults to xhigh (15k-50k token thinking
   blocks). Medium ≈ 3.6 token usage at a fraction of the latency. xhigh is
   reserved for complex coding tasks where latency is acceptable.
6. **Vendored chat template** — default Qwen3 template raises "System message
   must be at the beginning" when opencode sends 2+ system messages. The
   vendored template coalesces system messages, handles `reasoning_effort`
   (xhigh/medium/low), and preserves `<think>` blocks.
7. **Q4_K_XL quant** — fits one 24 GB GPU with full offload + 16k KV cache.
   Q8 (29 GB) needs both GPUs. Q5_K_M (19.8 GB) is a quality bump if context
   is kept small. Q4 + xhigh reasoning > Q8 + medium reasoning for accuracy.

## Management

- **Flake host:** `modules/hosts/mjolnir/` in nix-config
- **Deploy:** `just deploy mjolnir` (deploy-rs, magic rollback disabled)
- **SSH:** `ssh mjolnir` (via Tailscale, stable IP)
- **Secrets:** sops-nix with age key at `/var/lib/sops-nix/key.txt`
- **Model storage:** `/var/lib/llama-models/` (GGUF files)
- **vLLM cache:** `/var/lib/vllm/hf-cache/` (HuggingFace safetensors, currently
  holds Qwen3.8-27B-FP8 — can be cleaned if vLLM is not used)
