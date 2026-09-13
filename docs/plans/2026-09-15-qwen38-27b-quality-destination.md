# Destination — qwen3.8-27b agentic quality on mjolnir (single 24GB Turing card)

Epic: `nix-config-q27b-q` (beads). Map note; evidence log appended at the bottom.

## Why this exists

The 27B is the "smart" coder on `mjolnir` GPU0/8556 (hybrid-SSM `qwen35` arch: 16 full-attn +
48 delta-net layers, `qwen3-8-27b` in `modules/hosts/mjolnir/_llama-models.nix`). Three
reproducible-sounding failures in real OpenCode sessions:

1. **Doom loops** — repeats the same tool call / spins in reasoning instead of acting.
2. **Context drift** — loses track of which repo/directory it is in at long context.
3. **Misspelled tool calls** — malformed or hallucinated function/argument names, worse at depth.

Prior epics (`c3j` speed sweep, `zfw` fork/SWA work, `gbw`/`whf` residency) all optimised
**tok/s**. Nothing on this box measures quality, loop rate, or tool-call validity. That is the gap.

## Goal Artifacts (pass/fail, must be measurable)

| # | Artifact | Target on final config | How measured |
|---|---|---|---|
| G1 | **Loop resistance** | **0 loop events** across ≥30 scripted tool-calling turns | harness `loop_suite` + response/log parse |
| G2 | **Tool-call validity** | **≥99%** of emitted tool calls parse *and* name a tool present in `tools[]`; **0** path arguments that mismatch the planted path | harness `toolsuite` + response inspection |
| G3 | **Position/repo grounding** | **≥9/10** correct on repo-name / cwd / last-edited-file / branch probes at **≥80k** token depth; needle recalled **byte-exact** at **60k** depth | harness `grounding_suite` |
| G4 | **Usable context** | G1–G3 hold at ≥80k depth **and** decode ≥10 t/s **and** peak VRAM ≤23.0 GB **and** no server restart | harness depth ladder + `nvidia-smi` |
| G5 | **Landed in nix** | `just deploy mjolnir` green, final args in `_llama-models.nix`, before/after numbers in `results/2026-09-XX-27b-quality/`, wiki + beads updated | diff + redeploy + re-measure |

### Terms, defined so G1–G3 cannot be argued

- **Loop event** (G1, strict): within one run and before any new *user* message, either
  (a) the same `(tool_name, canonical_json_arguments)` pair is issued **≥3** times, or
  (b) a **non-mutating** tool returns byte-identical results **≥3** times. One event per
  streak, counted at the third occurrence. "Recovered" is *not* a discount — a loop event that
  the model later breaks out of still counts. Deliberately strict: the symptom being fixed is
  the loop, not its consequence.
- **Hallucinated path** (G2): the harness plants a canonical path string `P` in the last
  `W` tokens of the prompt it sends, records that it did so, and then compares every
  path-shaped tool argument to `P` and to the exact prompt string it sent. Mismatch with both
  ⇒ hallucinated. No appeal to "it should have known".
- **Needle** (G3): a 9-digit random id and a 24-char random token, planted **once** at a fixed
  depth, in a sentence the model has no reason to reproduce otherwise. **Recalled byte-exact**
  = the token appears verbatim in the answer. Score is `correct / probes` at each depth.
- **Noise floor**: every arm runs the suite **twice**. Baseline is accepted only if loop events
  agree exactly, grounding scores agree within 1 probe, validity within 1 point, and decode
  within 5%. A config change is real only if it beats that floor. The suite also has a
  **greedy sub-suite** (`--temp 0`, fixed seed) so sampler noise never masks a config effect.
- **Contention**: one client, serial requests, fixed seed per arm. The harness targets the
  sandbox port only — never `:8556` (flash-next, in use by the user). Concurrent traffic changes
  batch geometry and therefore timings; timings are reported, not judged, under contention.

Baseline (current config) numbers for G1–G4 are recorded first, in ticket 1 — every later
ticket is judged against them, not against a feeling.

## Constraints

- One 24 GB Turing card (sm_75). GGUF only. vLLM V1 floor is sm_80 — out.
- Must stay in the existing `llama-fleet` module (`llama.models.<name>` def in
  `_llama-models.nix`, `enable`/`gpu`/`port` flip in `default.nix`). Retired configs stay on
  disk as inert data; never delete.
- Two enabled models on one GPU, or two on one host port, fail eval by design.
- Sandbox = GPU1 (`qwen3-6-35b-iq4xs`, :8555) — user approved stopping it. GPU0 flash-next is
  off-limits.
- Images stay digest-pinned; store-built binaries (`llamaFork` / `llamaTurboq`) mount
  `/nix/store:ro`.
- OpenCode is the client: it sends **multiple system messages** and expects XML tool calls.
  `chat_template_kwargs` set client-side get silently dropped (OpenCode #26233) → kwargs live
  on the server command line.

## Research (2026-09-15)

**Model's own guidance.** Qwen recommends `temperature 1.0, top_p 0.95, top_k 20` for
general thinking mode and `temperature 0.6, top_p 0.8` for precise coding, and explicitly
**disables** repetition penalty (`repeat_penalty = 1.0`) for reasoning/instruct.
Source: https://github.com/QwenLM/Qwen3.6/discussions/3 .
Our live config is `--temp 0.8 --top-k 40 --top-p 0.95 --min-p 0` **plus `--repeat-penalty 1.05`**
— outside both published recipes, and 1.05 is not 1.0.

**Repeat penalty is a suspect for both #1 and #3.** Community reports on Qwen3.x: presence/
repeat penalties make looping *worse*, not better ("Presence penalty at 0.0 is the way to go,
adding more of that or repeat penalty makes it loop MORE"), and penalty over long code context
corrupts structural tokens → misspellings. Source: https://www.reddit.com/r/LocalLLaMA/comments/1tw6khv .

**SWA shrink is a suspect for #1, #2 and #3.** Our config force-overrides
`qwen35.attention.sliding_window=4096, swa_global_layers=8` (turboq fork only) purely for a
~+6 t/s gain at 15k+ depth; recall was validated with one needle 20k back. Same-family evidence
says the opposite direction fixes rail-opening:
- `--swa-full` "fixed all tool calling issues" for Qwen3.6-35B-A3B: "was getting tool call loops,
  hallucinated tool definitions, and going completely off the rails after about 15-20 messages."
  https://www.reddit.com/r/LocalLLaMA/comments/1tw60du/
- "Qwen3.5/3.6 GGUFs often need `--swa-full`" is repeated across llama.cpp threads
  (https://github.com/ggml-org/llama.cpp/issues/19894).
- Long-context loss with sliding window + KV reuse on this arch: "sometimes the model can't track
  the long context… `--cache-reuse 0` seems to fix it" — the same "evicted KV → forced full
  re-processing" mechanism we already document for flash-next
  (https://huggingface.co/unsloth/Qwen3.6-27B-GGUF/discussions/4).
- KV dtype at depth: "without Q8 KV cache quantization it is much better on longer context (BF16)"
  (same thread). Our 27B runs q8_0 K **and** V because f16 V at 128k + FA OOMs.

**Template governs loops more than the sampler does.** A llama.cpp-targeted hardened fork of the
fixed-template lineage exists — `Moore2877/Qwen-Fixed-Chat-Templates-llamacpp` (built on
froggeric v21.3 + agentic hardening, v20.1): structural **no-progress** detection
(`repeat_nudge_after`, skips mutating tools), **action ping-pong** detection
(`pingpong_nudge_after`, does *not* skip mutating tools), consecutive-error escalation,
vanished-tool detection, **argument-grounding rules** ("every required argument value must come
from the request, repo state, schema, or a prior tool result" — aimed exactly at hallucinated
paths), 4 distinct `reasoning_effort` tiers, and `preserve_reasoning` aliasing for
`--reasoning-preserve`. Recommended temperature with it: **0.70**. Also documents: grammar
enforcement is active on llama.cpp auto-parser builds **b8227+** and it only constrains the
**XML** format — JSON mode drops grammar enforcement *and* caused a measured 26–73× reasoning
blowup on this model class.
https://huggingface.co/Moore2877/Qwen-Fixed-Chat-Templates-llamacpp
Our vendored `modules/hosts/mjolnir/qwen3-chat-template.jinja` self-identifies as
`qwen3.8-froggeric-v22.5`, has error classification but **zero** loop/ping-pong/vanished
detection (grep: 0 matches for `nudge`).

**Spec-decode can silently damage output.** A documented (vLLM, same arch class) failure: CUDA
graphs + spec decode + prefix-cache hit at one residue mod 128 produced repetition collapse,
empty completions, and 400 tokens of fluent-but-wrong text with a malformed `<think>` — and
degenerate repetition scores *high* draft acceptance (79.7% vs 35–45% normal, distinct-word
ratio 0.051). Guards: distinct-word ratio, drafted-tokens-per-round >1.2× width, and sweep
lengths one token at a time instead of sampling. We already run `GGML_CUDA_DISABLE_GRAPHS=1`,
which is the mitigation, but our MTP acceptance (0.66–0.73) has never been checked against a
no-spec baseline for *quality*.
https://github.com/syv-ai/syv-docs (gotchas.md:353-418, 917-929, 828-849)

**Preserved thinking is a context-load lever.** `--chat-template-kwargs '{"preserve_thinking":true}'`
keeps reasoning blocks in history; field reports: "Preserve thinking was messing things up…
causing a lot of prompt reprocessing. Everything got faster and more consistent when I disabled
it" (https://www.reddit.com/r/LocalLLaMA/comments/1u8036x). Related history here: the
`--reasoning-preserve` CLI flag was a past OOM cause and must not come back.

**Speed levers found, not for this epic (record so nobody re-searches):** upstream now has
`--swa-full`, `--no-context-shift`, `--ctx-checkpoints` / `--checkpoint-every-n-tokens` (the
2026-09 "context checkpointing" work), `--fit/--fit-target/--fit-ctx`, `--spec-draft-type-k/v`,
and an in-flight PR that preserves context-checkpoint state across prompt reuse — the exact fix
for our "prompt cache can't resume → full re-prefill" cost. https://github.com/ggml-org/llama.cpp/pull/23881 ,
https://github.com/ggml-org/llama.cpp/pull/22679 . llama.cpp has **no** NVMe/LMCache/NIXL KV tier;
`--slot-save-path` + `POST /slots/:id?action=save|restore` is the disk path.

## Strategic Choices

1. Measure before tuning: the harness *is* the deliverable that makes every later knob arguable.
2. Prefer removing wrong settings over adding new machinery (off-spec sampling, forced SWA
   shrink, template lineage) — each is a subtraction, not new code.
3. One variable per arm wherever the variable is ours. **Exception, stated on purpose:** the
   published sampling recipes in ticket 2 (Qwen thinking-spec, template-author 0.70) are tested
   *as wholes* because they are external presets, not our parameters; if a preset wins, its
   knobs get decomposed in a follow-up arm before anything is adopted piecemeal.
4. All arms share the harness built in ticket 1 — same depth ladder, same seeds, same suites —
   and land in one results dir. No cross-session comparisons against memory.
5. Quality regressions are judged by task pass/fail + distinct-word ratio, never by acceptance %
   or tok/s.
6. Vendored template changes are in-repo files (governed); the HF-hosted template is not.
7. **Ownership boundary** (stops tickets 2 and 4 from stepping on each other): ticket 2 owns
   sampler args, `--reasoning-budget` and the *kwargs* passed to the template
   (`reasoning_effort`, `preserve_thinking`); ticket 4 owns the template **file**, the tool-call
   **format** and whether the pinned build **grammar-enforces** it. Neither crosses.

## Do-Not-Repeat (validated dead ends)

- Quants: Q4_K_XL vs Q4_K_M vs IQ4_XS vs Q5_K_M already measured (`c3j.7`, 2026-09-12/14).
  IQ4_XS +3.5% decode, −0.6pp PPL, −0.4pp MMLU-Pro; Q4_K_M was reverted for quality. Not open.
- `tbq4_0` KV on sm_75: slower at every depth (25.1 vs 31.1 @100k), worse MTP acceptance. Dead.
- `GGML_CUDA_FORCE_MMQ=true`: no measurable effect on sm_75 (46.18 vs 46.19 t/s). Dead.
- vLLM on Turing: AWQ+MTP `gptq_marlin_repack` OOM; TP2 ~36% below the fleet; hybrid-GDN MTP
  +76% latency / silent hangs even on H100. Dead.
- `-ctxcp` to shrink prompt-cache footprint: bounds rollback depth, measured worse (cached
  9,627 → 0). Dead.
- `--reasoning-preserve` CLI flag: past OOM cause. Dead.
- q4_0/q8_0 *weight* quants on hybrid-SSM: output corruption. Dead.
- Hand-rolled GGUF metadata parsers: produce confident wrong "critical bugs". Use `gguf_dump.py`.
- Believing partial-GDN-rollback PRs exist: #19670 and #22400 are CLOSED-unmerged.
- Imperative /var/lib builds and floating image tags: superseded; nix store + digest pins only.

## Tickets (frontier — deliberately not decomposed past the first measurable result)

1. **Harness + baseline** — build the G1–G4 suite, run it against the current config on the
   GPU1 sandbox, commit the numbers. Acceptance: script in repo, `results/` file with per-metric
   baseline, one command reproduces.
2. **Sampling & reasoning knobs** — `temp`/`top_k`/`top_p`/`min_p`/`repeat_penalty`/
   `reasoning_budget`/`reasoning_effort`/`preserve_thinking`, Qwen-spec vs current vs template-author.
3. **Attention & KV path** — forced SWA(4096/8) vs `--swa-full` vs native; KV K/V dtypes;
   `cache-reuse`; 128k vs 256k. Quality-vs-speed curve at depth.
4. **Tool-call & template path** — vendored template lineage/kwargs, XML vs JSON, whether the
   turboq fork's build actually grammar-enforces XML, `--reasoning-format` match.
5. **Spec-decode parity** — MTP on/off (and `GGML_CUDA_DISABLE_GRAPHS` interaction) against the
   same quality suite; repetition-collapse guards as acceptance instrumentation.

The deploy/documentation ticket is created **after** evidence lands — not before.

## Evidence log

- 2026-09-15: research above written; no measurements yet. Live config at time of writing:
  `llamaTurboq` package, `Qwen3.8-27B-UD-Q4_K_XL.gguf`, `-c 131072`, q8_0/q8_0 KV, SWA 4096/8,
  MTP `n-max 2 n-min 1`, `-ub 1024`, `-np 1`, FA on, `-cram 16384`,
  `--reasoning-format deepseek`, `--repeat-penalty 1.05`, `--temp 0.8 --top-k 40 --top-p 0.95
  --min-p 0`, vendored template + `{"reasoning_effort":"medium","preserve_thinking":true}`,
  `GGML_CUDA_DISABLE_GRAPHS=1`.
