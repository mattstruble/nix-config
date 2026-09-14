{ pkgs, lib, ... }:
let
  # llama.cpp fork (qwen4exp + MTP + MoE expert residency), sm_75 — built from
  # the pinned GitHub rev; the container runs it from the nix store (mounted
  # read-only), so the whole serving stack is deterministic. To bump: update
  # rev + hash in ./_llama-fork.nix.
  llamaFork = pkgs.callPackage ./_llama-fork.nix { };

  # Indras-Mirror turboq fork (Qwen35 SWA + fused TBQ4 KV FA + MTP), sm_75.
  llamaTurboq = pkgs.callPackage ./_llama-turboq.nix { };

  # Digest pinned — the floating-tag-moved lesson from the 3.6/3.8 retunes
  # applies to anything that ships inference code.
  upstreamImage = "ghcr.io/ggml-org/llama.cpp@sha256:41ebf873c2e085dcc3186dc4717ce8112bf8011aabd98038b6bb2b1fe66c86b9";

  # b10920 — needed for Gemma 4: the arch (``gemma4``, ``gemma4-assistant`` for the
  # MTP drafter) and ``--reasoning`` do not exist in older builds. b9752 fails with
  # "Rolling buffer type is not supported"; the layer name is misleading, the real
  # cause is unknown-model KV dimensions (tools/gpu1-model-selection/FINDINGS.md).
  upstreamGemmaImage = "ghcr.io/ggml-org/llama.cpp@sha256:6ac921528d613deb0fd142c654735e594a446a1c37a069eeab08d8fd974d4bec";

  # Only provides a filesystem + CUDA 12.6 userland; the fork binary comes from
  # the nix store and driver libs are injected by CDI.
  cudaImage = "nvidia/cuda@sha256:af25d2ef68f7aedaf0eb179e67773e64feefc3b65a12f59a6cd604ca7c53bb57";

  vendoredTemplate = "${./qwen3-chat-template.jinja}:/app/qwen3-chat-template.jinja:ro";

  sampling = [
    "--temp"
    "0.8"
    "--top-k"
    "40"
    "--top-p"
    "0.95"
    "--min-p"
    "0"
  ];

  # Qwen's own coding preset. Measured on the 27B (tools/27b-quality/FINDINGS.md,
  # 2026-09-12): +11% effective decode (46.2 vs 41.5 t/s over the tool suite, MTP
  # acceptance rises at lower entropy), identical grounding and tool validity, zero
  # loop events. Kept separate from `sampling` so the other models are untouched.
  samplingCoding = [
    "--temp"
    "0.6"
    "--top-k"
    "20"
    "--top-p"
    "0.8"
    "--min-p"
    "0"
  ];
in
{
  # Model definitions only — no enable/gpu here. Those are the switchboard in
  # ./default.nix, so a retired config stays on disk, inert, and is one line
  # away from running again. `port` is mkDefault so the switchboard can
  # re-point a model that shares the host with another one (two enabled models
  # on one host port fail evaluation).
  llama.models = {
    # Qwen3.8-Flash-Next (125B-class hybrid-SSM MoE) — coding/agentic.
    # Replaces Qwen3.8-27B (2026-09-01, user go/no-go): 125B-class quality +
    # 256k context outweigh the 2x decode slowdown.
    #
    # Requires the mjungnickel18 llama.cpp FORK — upstream cannot run this
    # model's MTP + MoE expert residency (branch qwen4exp-mtp-plus-moe-residency
    # @ 0384f5c, sm_75 via nixpkgs cudaPackages).
    #
    # Model: Q3_K_XL (92GB) with MoE experts split hot/cold: hot64 traced
    # experts in VRAM, cold on CPU via -ot "exps_cold=CPU". MTP sidecar is the
    # jockeupptaget Q8_0 extraction — its separate fc_embedding/fc_hidden
    # layout is what the fork expects; sidecars with the fused eh_proj layout
    # (the Q4_K_M ones) are incompatible.
    #
    # FA on is a hard requirement: q8_0 KV needs it, f16 KV OOMs on 24GB.
    # Uses the built-in template (--jinja, validated incl. tool calling). If
    # opencode's multi-system-message "System message must be at the beginning"
    # error shows up, mount the vendored template like qwen3-6-35b-iq4xs does.
    #
    # -ub 1024 (validated 2026-09-01): the FA compute workspace scales with
    # ubatch x KV depth — -ub 2048 OOMs at ~120k KV (segfault mid-prefill),
    # -ub 256 fits but prefills at only 60 tok/s. ub1024 is the fastest that
    # fits 24GB. Turns 2+ skip re-prefill via native slot prefix reuse, so only
    # session start pays it.
    #
    # Decode is ~10.3 tok/s (bench 2026-09-12: n-max3 n-min2 p-min0.75 =
    # 10.28 t/s avg, 3.8% drop from @4k to @15k). Updated from n-max6.
    qwen3-8-flash-next = {
      image = cudaImage;
      package = llamaFork;
      model = "/models/UD-Q3_K_XL-split96/Qwen3.8-Flash-Next-UD-Q3_K_XL-hot64.gguf";
      port = lib.mkDefault 8556;
      args = [
        "-md"
        "/models/mtp-fn-jockeupptaget-Q8_0.gguf"
        "--spec-type"
        "draft-mtp"
        "--spec-draft-n-max"
        "3"
        "--spec-draft-n-min"
        "2"
        "--spec-draft-p-min"
        "0.75"
        "--load-mode"
        "none"
        "--alias"
        "qwen3.8-flash-next"
        "-ot"
        "exps_cold=CPU"
        "-ngl"
        "99"
        "-c"
        "131072"
        "-np"
        "1"
        "-ub"
        "1024"
        "--cache-type-k"
        "q8_0"
        "--cache-type-v"
        "q8_0"
        "--flash-attn"
        "on"
        "--jinja"
        "--reasoning-budget"
        "8192"
        # Denser turn-boundary checkpoints. Default -cms 8192 skips a user turn
        # closer than 8192 tok to the last checkpoint, so mid-conversation
        # divergence re-prefills from the previous turn. 1024 gives every turn its
        # own checkpoint. a1v proved this is the only *config* lever on recurrent
        # re-prefill (see beads nix-config-a1v/nvt).
        "-cms"
        "1024"
        # Position-based checkpoints (nix-config-9g1): the fork patch
        # (0002-checkpoint-pos-step.patch) adds --checkpoint-pos-step N, which
        # also breaks the batch every N tokens so a checkpoint exists within N tok
        # of any divergence point — closes the residual that -cms alone can't.
        # Checkpoint state is the recurrent state (~137 MiB w/ MTP) stored in the
        # RAM prompt cache, NOT VRAM, so -c 131072 is unaffected.
        #
        # COVERAGE PRIORITY (nix-config: 2026-09-05). Two coupled knobs, one
        # formula: coverage = ctxcp * pos_step, RAM = ctxcp * 137 MiB.
        #   32 x 2048 = 65,536 tok covered, 4.38 GiB  <- what shipped first
        #   16 x 4096 = 65,536 tok covered, 2.19 GiB  <- now
        # Same coverage at half the RAM, and half the checkpoint-creation churn
        # (one 137 MiB sync copy per 4096 prefill tokens instead of per 2048).
        # Why it matters: at 32 x 2048 a 128k session only had checkpoints over
        # its LAST 64k, so a deep divergence (compaction 127k->39k) still
        # full-re-prefilled; and the denser checkpoints pushed the prompt-cache
        # entry to 8360 MiB against the 8192 MiB -cram cap, where alloc() SKIPS
        # the whole entry (no eviction) -> prompt_clear() -> full re-prefill.
        # The patch was causing the thing it exists to prevent. Worst-case
        # residual is now 4096 tok (~27 s) vs 54-79 s pre-patch. Host has
        # ~1.3 GB MemAvailable, so halving the footprint is the point.
        # NOTE: pos_step 2048 == n_batch default, so the batch break was free;
        # 4096 still breaks on a 2048 boundary (2 batches), so it stays free.
        "--checkpoint-pos-step"
        "4096"
        # Max context checkpoints per slot (default 32). See the formula above.
        "-ctxcp"
        "16"
        # EXPERIMENT (5f8, 2026-09-04): enable POST /slots?id_slot=N&action=save|restore
        # to a host dir, to test NVMe recovery of an aborted slot on hybrid memory.
        "--slot-save-path"
        "/slots-save"
      ]
      ++ sampling;
      volumes = [
        "/var/lib/llama-models:/models"
        "/var/lib/llama-slots:/slots-save"
      ];
    };

    # Same model on the same GPU, 256k context, NO MTP: MTP + 256k KV + FA
    # workspace = 24.05GB > 24GB. Bench: prefill 54 tok/s, decode 11 tok/s at
    # 257k depth, long-context retention correct. Use when a session outgrows
    # 128k; 3.6 on GPU 1 covers long-context speed in the meantime.
    # Mutually exclusive with qwen3-8-flash-next (same GPU — the module's
    # assertion refuses to evaluate both).
    qwen3-8-flash-next-256k = {
      image = cudaImage;
      package = llamaFork;
      model = "/models/UD-Q3_K_XL-split96/Qwen3.8-Flash-Next-UD-Q3_K_XL-hot64.gguf";
      port = lib.mkDefault 8557;
      args = [
        "--alias"
        "qwen3.8-flash-next"
        "-ot"
        "exps_cold=CPU"
        "-ngl"
        "99"
        "-c"
        "262144"
        "-np"
        "1"
        "-ub"
        "256"
        "--cache-type-k"
        "q8_0"
        "--cache-type-v"
        "q8_0"
        "--flash-attn"
        "on"
        "--jinja"
        "--reasoning-budget"
        "8192"
      ]
      ++ sampling;
    };

    # Qwen3.6-35B-A3B MoE — dispatch/chat/HA/n8n (speed-primary).
    # IQ4_XS GGUF (unsloth -MTP repo), 256k context, full offload (-ngl 99),
    # -np 2 (128k per user). Tuned 2026-08-27 after A/B bench: FA off (hybrid
    # SSM fattn path broken in this build — 51k prefill 14.6 vs 951 tok/s),
    # q8_0 K + f16 V KV (3.3x decode vs q5_1, 14/14 planted-name quality), MTP
    # removed (draft path O(n) at length: 5.7 tok/s @16k vs 53 without).
    # Re-enable MTP once llama.cpp upstream #24670 (draft path missing SSM
    # state) is fixed and lands in a new pinned image build.
    qwen3-6-35b-iq4xs = {
      image = upstreamImage;
      model = "/models/Qwen3.6-35B-A3B-MTP-UD-IQ4_XS.gguf";
      port = lib.mkDefault 8555;
      volumes = [
        "/var/lib/llama-models:/models"
        vendoredTemplate
      ];
      args = [
        "--alias"
        "Qwen3.6-35B-A3B"
        "-ngl"
        "99"
        "-c"
        "262144"
        "--cache-type-k"
        "q8_0"
        "--cache-type-v"
        "f16"
        "--jinja"
        "--chat-template-file"
        "/app/qwen3-chat-template.jinja"
        "--chat-template-kwargs"
        ''{"reasoning_effort":"medium","preserve_thinking":true}''
        "--reasoning-budget"
        "8192"
        "-ub"
        "256"
        "-np"
        "2"
        "--flash-attn"
        "off"
      ]
      ++ sampling;
    };

    # Qwen3.8-27B — dense 27B (qwen35 arch: 16 full-attn + 48 delta-net layers),
    # the "smart" model. Q4_K_XL GGUF, 128k context, q8_0 KV, MTP n-max 2,
    # flash-attn on, single user (-np 1) — full context for one coder.
    # 2026-09-11: runs the Indras-Mirror turboq fork (llamaTurboq) with SWA
    # (window 4096, 8 global layers). Bench on the 3090, same GGUF:
    #   depth:  2k    15k    50k    100k
    #   old:   47.2  35.2   31.8   29.1   (38% depth cliff)
    #   SWA:   44.7  40.9   38.0   31.1   (30% cliff, +5.7/+6.2/+2.0 at 15k+)
    # SUPERSEDED (2026-09-12, nix-config-qjz): those are decode-speed numbers and
    # the old "SWA recall verified via the 8 global layers" line was never a recall
    # measurement. Re-measured with a scored recall harness
    # (tools/27b-quality/harness.py): forced SWA(4096/8) = 0/6 at 80k, dense = 6/6,
    # and dense is faster at depth too. The override is gone from the args below.
    # TBQ4 KV tested and rejected on sm_75 (slower at every depth, 25.1 vs 31.1
    # @100k) — see qwen3-8-27b-turboq below.
    # FA on is a hard requirement: quantized V cache needs it, and f16 V at
    # 128k OOMs. 256k infeasible on 24GB.
    # Takes 8556 (the coding endpoint) when it replaces Flash-Next, so clients
    # need no change; the alias differs, so pick by name if both ever run.
    # 2026-09-14: Reverted Q4_K_M back to Q4_K_XL (quality degradation with
    # Q4_K_M). 2026-09-14: ub1024 restored (verified 2026-09-12: +6.9% prefill,
    # +4.1% decode vs ub256; VRAM headroom 3.1GB sufficient).
    qwen3-8-27b = {
      image = cudaImage;
      package = llamaTurboq;
      model = "/models/Qwen3.8-27B-UD-Q4_K_XL.gguf";
      port = lib.mkDefault 8556;
      volumes = [
        "/var/lib/llama-models:/models"
        vendoredTemplate
      ];
      args = [
        "--alias"
        "qwen3.8-27b"
        "-ngl"
        "99"
        "-c"
        "131072"
        "--cache-type-k"
        "q8_0"
        "--cache-type-v"
        "q8_0"
        # NO SWA override here, on purpose (2026-09-12, nix-config-qjz).
        # The Qwen3.8-27B GGUF ships no sliding window: the forced
        # `--override-kv qwen35.attention.sliding_window=int:4096,...swa_global_layers=int:8`
        # did not shrink an existing window, it CREATED one, and the fork's
        # swa_global_layers escape hatch does not keep long-range recall. Measured
        # with tools/27b-quality/harness.py (identity + needle probes, byte-exact
        # scoring, prompt built from real repo+C++ source): with the override the
        # model answers 2/6 at 20k, 1/6 at 50k, 0/6 at 80k — it cannot see its own
        # repo/cwd/branch in the system prompt past ~4k tokens. Dense: 6/6 at 20k,
        # 5/6 at 50k, 6/6 at 80k, 6/6 at 100k and 120k. Dense is also FASTER at
        # depth (31.4 vs 29.0 t/s @80k) and costs 2.1 GiB more VRAM (23.05 of 24 GB
        # at -c 131072, allocated up front, verified at 120k depth). The old
        # "SWA recall verified via the 8 global layers" note below was a speed
        # anecdote, not a recall measurement. Full table: tools/27b-quality/FINDINGS.md.
        "--jinja"
        "--chat-template-file"
        "/app/qwen3-chat-template.jinja"
        "--chat-template-kwargs"
        ''{"reasoning_effort":"medium","preserve_thinking":true}''
        "--reasoning-budget"
        "8192"
        "--spec-type"
        "draft-mtp"
        "--spec-draft-n-max"
        "2"
        "--spec-draft-n-min"
        "1"
        "-ub"
        "1024"
        "-np"
        "1"
        "--flash-attn"
        "on"
        # -cram 16384: at 118k the cache entry is
        # ~10 GiB (5.5 GiB state + checkpoints) and alloc() SKIPS any single
        # entry larger than -cram (it does not evict), so nothing is saved,
        # prompt_load finds nothing and prompt_clear() drops the conversation —
        # the re-prefill we are fixing, from the other direction. 16 GiB holds
        # one full 128k session: 0 overflow warnings, RSS 16.38 GiB on a host
        # with 27 GiB available.
        # Do NOT try to shrink the entry with -ctxcp instead. -ctxcp bounds how
        # far back the slot can roll back, not just its cache footprint: at
        # -ctxcp 2 (2 x 17.9k turn spacing = 36k of coverage) every divergent
        # request lost prefix reuse outright (cached 9,627 -> 0) and resume got
        # worse than base. Measured 2026-09-06.
        "-cram"
        "16384"
        "--reasoning-format"
        "deepseek"
        # 1.0 = penalty disabled. Measured 1.05 vs 1.0 (arms S3/S2 on the dense
        # config): no difference in grounding or tool validity, no loop events in
        # either; 1.0 is the higher-fidelity setting, so keep it and fix loops at
        # the cause (context) rather than with a token penalty.
        "--repeat-penalty"
        "1.0"
      ]
      ++ samplingCoding;
    };

    # DORMANT (2026-09-11, nix-config-vjd): TBQ4 KV variant of the 27B.
    # Measured on the 3090: SLOWER than q8_0 KV at every depth (43.7/38.4/31.9/
    # 25.1 @ 2k/15k/50k/100k vs q8_0+SWA's 44.7/40.9/38.0/31.1) — the fused
    # TBQ4 FA kernel is not fast on sm_75, and TBQ4 KV also drops MTP acceptance
    # (0.64-0.85 vs 0.79). The fork's headline 70 t/s @62K did not reproduce.
    # Kept as inert data per the switchboard rule; the winning config
    # (turboq + q8_0 + SWA) lives in qwen3-8-27b above.
    qwen3-8-27b-turboq = {
      image = cudaImage;
      package = llamaTurboq;
      model = "/models/Qwen3.8-27B-UD-Q4_K_XL.gguf";
      port = 8557;
      volumes = [
        "/var/lib/llama-models:/models"
        vendoredTemplate
      ];
      args = [
        "--alias"
        "qwen3.8-27b-turboq"
        "-ngl"
        "99"
        "-c"
        "131072"
        "--cache-type-k"
        "tbq4_0"
        "--cache-type-v"
        "tbq4_0"
        "--override-kv"
        "qwen35.attention.sliding_window=int:4096,qwen35.attention.swa_global_layers=int:8"
        "--jinja"
        "--chat-template-file"
        "/app/qwen3-chat-template.jinja"
        "--chat-template-kwargs"
        ''{"reasoning_effort":"medium","preserve_thinking":true}''
        "--reasoning-budget"
        "8192"
        "--spec-type"
        "draft-mtp"
        "--spec-draft-n-max"
        "2"
        "--spec-draft-n-min"
        "1"
        "-ub"
        "256"
        "-np"
        "1"
        "--flash-attn"
        "on"
        "-cram"
        "16384"
      ]
      ++ sampling;
    };

    # Gemma 4 26B-A4B (MoE, 4B active) — voice + n8n classification.
    # Chosen over the Qwen3.6-35B-A3B incumbent by the bake-off in
    # tools/gpu1-model-selection/ (FINDINGS.md has every number: same harness, same
    # calibrated prompt depths, server timings on both sides).
    #
    # Why: 2.4-2.6x the prefill throughput (3221/2950/1934 t/s at 4k/20k/60k vs
    # 1319/1139/745), 135 t/s decode with the MTP drafter vs 103, and it is the only
    # one of the two that answers a voice turn on time (10/10 turns speak within
    # 0.07 s; the incumbent manages 6/10 at 8.5 s, because reasoning_effort=medium
    # + preserve_thinking emit ~3800 chars of thinking first). Recall: 4/4 needle +
    # grounding through 100k at any KV dtype; the incumbent loses a needle at 100k.
    #
    # Why it is NOT a clean win: single-turn tool choice is 0.60 vs 0.90 and
    # multi-turn agent closure 2/3 vs 3/3 — Gemma prefers the one tool that needs no
    # arguments. Putting the Home Assistant service catalogue in the prompt does not
    # fix it (0.60 at temp 0.2 and 0.7), so it is the model on this task shape, not
    # a prompt artifact. If the HA flow degrades after the swap, flip back: the
    # incumbent is inert, one line away.
    #
    # `--reasoning off` is the load-bearing flag. Reasoning on triples output volume
    # and n8n flows passing max_tokens ~= 800 get an empty result. It is also what
    # makes the schema bind: with thinking on, the incumbent violates a required
    # enum 4/4 even non-streaming with json_schema set (the schema is in the
    # request; the sampler ignores it).
    #
    # Model + drafter are imperative downloads (the host has no direct HF access):
    #   hf-mirror.com/unsloth/gemma-4-26B-A4B-it-GGUF/.../gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf
    #   hf-mirror.com/unsloth/gemma-4-26B-A4B-it-GGUF/.../MTP/mtp-gemma-4-26B-A4B-it-Q8_0.gguf
    # The repo-root mirror of the MTP file is a 0-byte placeholder; the real one is
    # under MTP/. Both live in /var/lib/llama-models (mounted at /models).
    #
    # FA on is mandatory: --flash-attn off cannot build a context at -ub 512 or 2048
    # (tested). q8_0 KV is free recall-wise (q4_0/q8_0/f16 all 4/4 at 100k), so the
    # saved VRAM goes to the drafter instead. -ub 512 measures the same as 2048
    # without MTP, so if the drafter ever has to go, drop -ub to 512 rather than
    # shrinking the context.
    # Reasoning on Gemma 4 is a binary switch, not a ladder: --reasoning-effort
    # low/medium/high/auto measure identical (1066 chars of thinking before the answer,
    # 1.90s to speakable audio, against 0.06s with it off), and no per-request knob moves
    # it -- reasoning_effort, chat_template_kwargs.thinking, thinking_budget and
    # reasoning.exclude all leave thinking untouched. So a thinking agentic flow needs its
    # own server; do not add reasoning_effort to chat_template_kwargs expecting a middle
    # setting. Thinking also costs enum compliance: 8/8 jstress violations against 0.
    # -np 1 is deliberate: two simultaneous 60k callers already cost ~40s each (1.5x), and
    # -np 2 needs -ub 512, which loses single-stream work too (20k round trip 8.9s -> 11.1s).
    gemma-4-26b-a4b = {
      image = upstreamGemmaImage;
      model = "/models/gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf";
      port = lib.mkDefault 8555;
      args = [
        "--alias"
        "gemma-4-26b-a4b"
        "-md"
        "/models/mtp-gemma-4-26B-A4B-it-Q8_0.gguf"
        "--spec-type"
        "draft-mtp"
        "--spec-draft-n-max"
        "2"
        "--spec-draft-p-min"
        "0.75"
        "-ngl"
        "99"
        "-c"
        "131072"
        "-np"
        "1"
        "-ub"
        "2048"
        "--cache-type-k"
        "q8_0"
        "--cache-type-v"
        "q8_0"
        "--flash-attn"
        "on"
        "--jinja"
        "--reasoning"
        "off"
      ]
      ++ samplingCoding;
    };

    # Same weights, 256k context, no drafter (MTP + 256k KV does not fit 24GB).
    # Measured 21890 MiB at -c 262144: prefill 919 t/s and decode 47 t/s at 200k,
    # needle intact at 200k — but repo/cwd/branch grounding from the system prompt
    # is LOST at 200k (it holds at 120k). Fine for "read this long document", not
    # fine for an agentic session that must remember where it is. f16 KV does not
    # fit at 256k. Do not enable together with gemma-4-26b-a4b: they share a GPU,
    # and the guard in ../../../services/llama-fleet.nix only catches duplicate
    # ports, not duplicate GPUs.
    gemma-4-26b-a4b-longctx = {
      image = upstreamGemmaImage;
      model = "/models/gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf";
      port = lib.mkDefault 8557;
      args = [
        "--alias"
        "gemma-4-26b-a4b-longctx"
        "-ngl"
        "99"
        "-c"
        "262144"
        "-np"
        "1"
        "-ub"
        "2048"
        "--cache-type-k"
        "q8_0"
        "--cache-type-v"
        "q8_0"
        "--flash-attn"
        "on"
        "--jinja"
        "--reasoning"
        "off"
      ]
      ++ samplingCoding;
    };

    # DORMANT (c3j.7, 2026-09-12): Quant variant tests. Q4_K_M (16GB), Q5_K_M
    # (18GB) downloaded. IQ4_XS downloading. jonidimo: AD-Q4_K_M 765 MiB
    # smaller, same quality as Q4_K_XL. Tests: decode speed, VRAM, quality.
    qwen3-8-27b-Q4_K_M = {
      enable = false;
      gpu = 1;
    };
    qwen3-8-27b-Q5_K_M = {
      enable = false;
      gpu = 1;
    };
    qwen3-8-27b-IQ4_XS = {
      enable = false;
      gpu = 1;
    };
  };
}
