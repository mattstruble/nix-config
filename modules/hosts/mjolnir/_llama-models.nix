{ pkgs, lib, ... }:
let
  # llama.cpp fork (qwen4exp + MTP + MoE expert residency), sm_75 — built from
  # the pinned GitHub rev; the container runs it from the nix store (mounted
  # read-only), so the whole serving stack is deterministic. To bump: update
  # rev + hash in ./_llama-fork.nix.
  llamaFork = pkgs.callPackage ./_llama-fork.nix { };

  # Digest pinned — the floating-tag-moved lesson from the 3.6/3.8 retunes
  # applies to anything that ships inference code.
  upstreamImage = "ghcr.io/ggml-org/llama.cpp@sha256:41ebf873c2e085dcc3186dc4717ce8112bf8011aabd98038b6bb2b1fe66c86b9";

  # Only provides a filesystem + CUDA 12.6 userland; the fork binary comes from
  # the nix store and driver libs are injected by CDI.
  cudaImage = "nvidia/cuda@sha256:af25d2ef68f7aedaf0eb179e67773e64feefc3b65a12f59a6cd604ca7c53bb57";

  vendoredTemplate = "${./qwen3-chat-template.jinja}:/app/qwen3-chat-template.jinja:ro";

  sampling = [
    "--temp"
    "0.6"
    "--top-k"
    "20"
    "--top-p"
    "0.95"
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
    # Decode is ~9.5 tok/s on real traffic (NOT the 19.5 in the old bench
    # comment — that was a badly configured first test).
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
        "6"
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
      volumes = [ "/var/lib/llama-models:/models" "/var/lib/llama-slots:/slots-save" ];
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

    # Qwen3.8-27B — DORMANT since 2026-09-01 (replaced on GPU 0 by Flash-Next).
    # Q4_K_XL GGUF, 128k context, q8_0 KV, MTP n-max 2, flash-attn on, single
    # user (-np 1) — full context for one coder.
    # Bench 2026-08-27 (pinned build): prefill 626/575/485 tok/s @15k/30k/60k,
    # decode 43.7/43.6/35.0, MTP 1.68-1.79x with no O(n) collapse at length
    # (unlike 3.6), quality 14/14, tool calling OK. FA on is a hard
    # requirement: quantized V cache needs it, and f16 V at 128k OOMs. 256k
    # infeasible on 24GB. Cold-start first request after load 96.4s @15k
    # (warm ~24s).
    # Takes 8556 (the coding endpoint) when it replaces Flash-Next, so clients
    # need no change; the alias differs, so pick by name if both ever run.
    qwen3-8-27b = {
      image = upstreamImage;
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
        # Consult the RAM prompt cache on *every* request (nix-config-l4s).
        # get_available_slot() only calls prompt_save/prompt_load when
        # update_cache is set, and it sets update_cache=false whenever it
        # LCP-selects a slot with f_keep >= 0.5. After a pi compaction the slot
        # holds a short summary, so the next big turn still scores f_sim ~0.15
        # (> the 0.10 thold) with f_keep ~0.73 -> cache never consulted -> the
        # entry holding the real history at f_keep 1.00 is ignored and the turn
        # full-re-prefills. 0.0 skips the LCP block, so every request takes the
        # LRU branch and update_cache is always true.
        # Measured on mjolnir GPU1 against the live production arg set:
        #   resume-after-compaction @118k: 299.2s/108857 tok -> 6.6s/987 tok
        #   resume-after-compaction @17k :  23.2s/ 14349 tok -> 3.4s/ 1202 tok
        #   divergent mid-turn probe     : cached 9,627 in both (no regression)
        #   appends turn0-5              : wall and cached identical to base
        # SAFE ONLY WITH -np 1 — with several slots the LCP block is what routes
        # each conversation to its own slot; disabling it makes them ping-pong.
        "--slot-prompt-similarity"
        "0"
        # -sps 0 alone does NOT fix the deep case: at 118k the cache entry is
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
      ]
      ++ sampling;
    };
  };
}
