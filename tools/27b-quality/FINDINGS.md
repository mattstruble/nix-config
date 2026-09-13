# qwen3.8-27b agentic quality on mjolnir — findings

Date: 2026-09-12. Epic: `nix-config-qjz`. Host: mjolnir (2× Titan RTX 24GB, sm_75),
GPU1 sandbox on `:8558`, model `/models/Qwen3.8-27B-UD-Q4_K_XL.gguf`, turboq fork
`llama-cpp-turboq-0.3.0-8f2b243`. GPU0 / `:8556` (flash-next) was never touched.
829 measured requests across 22 arm runs.

Reported symptoms: the endpoint **loses context, repeats itself (doom loop), misfires
tool calls, and sometimes returns an empty message.**

## Headline

**The forced SWA override was the context loss.** `qwen35.attention.sliding_window=int:4096,
qwen35.attention.swa_global_layers=int:8` did not shrink an existing window — the GGUF ships
no sliding window — it **created** one, and the fork's `swa_global_layers` escape hatch does
not preserve long-range recall. With it, the model cannot report its own repository, working
directory or branch from the *system prompt* once the prompt passes ~4k tokens: 2/6 at 20k,
1/6 at 50k, **0/6 at 80k**. Without it: 6/6 at 20k, 5/6 at 50k, **6/6 at 80k, 100k and 120k**.
Dense is also *faster* at depth (31.4 vs 29.0 t/s @80k) and costs 2.1 GiB more VRAM
(23.05 of 24 GB at `-c 131072`, allocated up front, verified at 120k depth).

**The doom loop is a tool-call format mismatch, not sampling.** With
`"tool_call_format":"json"` in `--chat-template-kwargs`, the server returns
`HTTP 500 Failed to parse tool call arguments as JSON` and the model re-emits the same
tool call ~20 times inside a single completion (50 `<tool_call>`/`<function=` markers
measured in one response). With the XML path (no `tool_call_format` kwarg — what is deployed)
**zero loop events** in 19 arms, and 0 bad tool names / 0 parse failures.

**Empty messages did not reproduce**: 0 empty-content turns and every `finish_reason` was
`stop` (never `length`) across the whole sweep. Leading hypothesis, unconfirmed: a client that
asks for JSON tool calls gets the 500 above and surfaces it as an empty message.

## The ladder (grounding, byte-exact scoring)

Probes ask for repo / cwd / branch / last-edited-file (all in the system prompt) plus a numeric
id and a token needle planted ~19k tokens in, so at 80k depth the answers sit ~60k tokens back.
Prompt = monotone prefixes of real `.nix` config + llama.cpp C++ source, so deeper probes reuse
the KV prefix. Identities contain no substring present in the corpus (contamination checked).

| arm | delta vs prod | VRAM | 2k | 20k | 50k | 80k | tools | t/s |
|---|---|---|---|---|---|---|---|---|
| A0_prod | — (run 1) | 20992 | 4/4 | 2/6 | 1/6 | **0/6** | 14/16 | 41.7 |
| A0_prod_run2 | repeat of prod | 20996 | 4/4 | 2/6 | 1/6 | **0/6** | 14/16 | 41.8 |
| S1_qwen_think | temp 1.0 / top_k 20 | 20992 | 4/4 | 1/6 | 0/6 | 0/6 | 15/16 | 46.2 |
| S2_coding | temp .6 / top_p .8 / top_k 20 / rp 1.0 | 20992 | 4/4 | 1/6 | 0/6 | 0/6 | 15/16 | 47.2 |
| S3_norepeat | repeat-penalty 1.0 | 20992 | 4/4 | 1/6 | 0/6 | 0/6 | 15/16 | 47.2 |
| S4_topk20 | top_k 20 | 20992 | 4/4 | 2/6 | 1/6 | 0/6 | 14/16 | 42.8 |
| S5_nopreserve | `preserve_thinking:false` | 20992 | 4/4 | 2/6 | 1/6 | 0/6 | 14/16 | 41.8 |
| **K1_swafull** | −override, +`--swa-full` | 23096 | 4/4 | **6/6** | 5/6 | **6/6** | 14/16 | 41.5 |
| **K2_native** | **−override** | 23096 | 4/4 | **6/6** | 5/6 | **6/6** | 14/16 | 41.5 |
| K3_f16v | V cache f16 (override kept) | 21734 | 4/4 | 2/6 | 1/6 | 0/6 | 13/15 | 41.9 |
| K4_creuse0 | `--cache-reuse 0` | 20992 | 4/4 | 2/6 | 1/6 | 0/6 | 14/16 | 41.9 |
| T1_hardtpl | HF "fixed" template | 20992 | 4/4 | 2/6 | 2/6 | 0/6 | 13/15 | 44.9 |
| T2_json | +`tool_call_format:json` | 20992 | — | — | — | — | aborted: HTTP 500 | — |
| M1_nomtp | −MTP | 19426 | 4/4 | 2/6 | 1/6 | 0/6 | 13/15 | **27.0** |
| M2_graphs | `GGML_CUDA_DISABLE_GRAPHS=0` | 20992 | 4/4 | 2/6 | 1/6 | 0/6 | 14/16 | 41.8 |
| **G1_k2_coding** | dense + coding sampler | 23096 | 4/4 | **6/6** | 5/6 | **6/6** | 15/16 | **46.2** |
| G2_k2_hardtpl | dense + hardened template | 23096 | 4/4 | 5/6 | 5/6 | 6/6 | 14/16 | 44.4 |
| G3_k2_hard_coding | dense + hardened + coding | 23096 | 4/4 | 5/6 | 5/6 | 6/6 | 15/16 | 47.8 |
| G4_k2_nopreserve | dense, no preserve_thinking | 23096 | 4/4 | 6/6 | 5/6 | 6/6 | 14/16 | 41.5 |
| V2_final_deep | dense + coding, deep ladder | 23096 | — | — | — | **100k: 6/6, 120k: 6/6** | 15/16 | 46.2 |

`tools` = turns that produced tool calls / total turns. The remainder are the model's final
DONE/answer turns, not failures — `bad names` and `parse failures` were 0 everywhere except the
JSON arm. K1 ≡ K2 in every field: `--swa-full` is a no-op once there are no SWA layers, which
proves the *override* (not the cache flag) is the variable.

## Long-session tool suite (20k tokens of simulated earlier turns)

Same three scenarios (explore+summarise, edit that fails on first try, planted path), prefixed
with 20k tokens of prior context — 5× the SWA window, i.e. the pi condition.

| arm | valid turns | calls | bad names | parse fails | loop events | max call markers in one completion | turns used |
|---|---|---|---|---|---|---|---|
| X1_override (prod sampler) | 15/16 | 15 | 0 | 0 | 0 | 0 | 18 |
| X2_final (dense + coding) | 12/14 | 12 | 0 | 0 | 0 | 0 | 16 |
| X3_json (`tool_call_format:json`) | 8/8 | 8 | 0 | 0 | **2 runaway** | **50** | — |

Dense reaches the answer in fewer turns (16 vs 18) and repeats one read instead of three; the
blind config wanders (`ls /work/…`, `find`, re-reads the same file 3×). The runaway only appears
when the emitted format and the parsed format disagree.

## Decisions applied to `modules/hosts/mjolnir/_llama-models.nix`

1. **Delete the `--override-kv … sliding_window/swa_global_layers` pair** from `qwen3-8-27b`.
   Cost: 2.1 GiB VRAM (23.05/24 GB at 131k). This is the fix for context loss.
2. **Adopt Qwen's coding sampler** for this endpoint only (`samplingCoding`: temp 0.6, top_k 20,
   top_p 0.8, min_p 0, repeat-penalty 1.0). +11% effective decode, identical grounding and tool
   validity. `--repeat-penalty` is *not* a loop fix and was lowered, not raised.
3. **Keep the vendored `qwen3-chat-template.jinja`.** The HF "fixed templates for llamacpp"
   variant measured slightly *worse* (5/6 vs 6/6 at 20k) — no reason to switch lineage.
4. **Never set `tool_call_format`** — the XML path is what the fork parses; JSON is a 500 plus a
   runaway loop.
5. **Keep MTP** (`draft-mtp`, n-max 2, n-min 1): M1_nomtp scored the identical ladder profile at
   27.0 t/s vs 41.7 t/s (+54% from MTP). Keep `GGML_CUDA_DISABLE_GRAPHS=1` (M2 changed nothing).
6. `-cram` was measured at 1024 in the sandbox only (host had ~4 GiB free while flash-next holds
   its mmap); production keeps 16384 — the suites never rely on cross-prompt persistence.

## Re-running

On mjolnir, `/var/lib/llama-quality/` (sandbox container on GPU1, fleet unit
`docker-llama-qwen3-6-35b-iq4xs` stopped for the duration):

```sh
python3 harness.py --base http://localhost:8558 --label A0_prod \
  --outdir /var/lib/llama-quality --gpu 1 --corpus corpus.txt \
  --depths 2000,20000,50000,80000 --greedy-tools      # ladder + tool suite
python3 harness.py ... --tools-only --long-tokens 20000   # long-session tool suite only
./arms.sh    # the full arm queue, resumable via <label>.done
```

Corpus: `./corpus.sh` on mjolnir (reads `/etc/nixos` + the llama.cpp checkout; `corpus.txt` is
not checked in). Needle inserted at char 60000. `corpus.txt` is regenerable; the needle id/token and the probe identities
in `harness.py` must stay mutually absent (checked at build time).

Harness gaps worth knowing: cross-turn loop detection needs ≥3 identical (tool, canonical args)
in one run, so a short suite cannot show a *real* doom loop — the intra-completion marker count
(`markers`) is what caught X3; `--slot-save-path`/abort-rollback behaviour is not covered.
