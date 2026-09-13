#!/usr/bin/env python3
"""harness.py — quality/reliability measurement for the mjolnir 27B coding endpoint.

Runs ON mjolnir (stdlib only). Measures the three reported symptoms:
  G1 loop events      — same (tool, canonical args) >=3x, or non-mutating tool with
                        byte-identical result >=3x, within one run (no user turn reset).
  G2 tool validity    — tool_calls parse, name a real tool, path args match the planted path.
  G3 grounding        — repo / cwd / branch / last-edited-file / needle probes at depth.
  G4 cost             — decode t/s, prefill t/s, peak VRAM, cached tokens.

Every number comes from the server's own response (usage + timings), never from guesses.

  python3 harness.py --base http://localhost:8558 --label A0_prod \
      --outdir /var/lib/llama-quality --gpu 1 [--depths 2000,20000,50000,80000]
"""
import argparse
import collections
import json
import os
import re
import statistics
import subprocess
import threading
import time
import urllib.error
import urllib.request

API_KEY = "foo"  # pragma: allowlist secret  # llama.cpp dev endpoint, no auth
# Distinctive identities: no substring here may appear in the corpus, so a correct
# answer cannot be contamination.
IDENT = {
    "repo": "nix-config-q7",
    "cwd": "/work/nix-config-q7",
    "branch": "feat/27b-quality-sweep-8827",
    "lastfile": "_llama-models-9f3c.nix",
}
NEEDLE_ID = "741592638"
NEEDLE_TOK = "XK3Q9M2TVR7PLW0JH4B8NCAD"  # pragma: allowlist secret  # synthetic recall probe
SYSTEM = (
    "You are a coding agent.\n"
    "Repository: {repo}\nWorking directory: {cwd}\nGit branch: {branch}\n"
    "Most recently edited file: modules/hosts/mjolnir/{lastfile}"
).format(**IDENT)

PROBES = [
    ("repo", "Which repository are you working in? Answer with the name only.", IDENT["repo"]),
    ("cwd", "What is your working directory? Answer with the path only.", IDENT["cwd"]),
    ("branch", "Which git branch are you on? Answer with the branch name only.", IDENT["branch"]),
    ("lastfile", "Which file did you most recently edit? Answer with the file name only.", IDENT["lastfile"]),
    ("needle_id", "What is the reference id mentioned in the notes above? Answer with the id only.", NEEDLE_ID),
    ("needle_tok", "What is the reference token mentioned in the notes above? Answer with the token only.", NEEDLE_TOK),
]

# ---- synthetic repo for the tool suite (deterministic, no external deps) ----
FS0 = {
    "/work/nix-config-q7/modules/services/llama-fleet.nix": (
        "# llama fleet module\n"
        "assertions = [\n  (noDuplicates (m: m.gpu) \"GPU\")\n"
        "  (noDuplicates (m: m.port) \"host port\")\n];\n"
    ),
    "/work/nix-config-q7/modules/hosts/mjolnir/_llama-models.nix": (
        "  qwen3-8-27b = {\n    args = [\n"
        "        \"--temp\"\n        \"0.8\"\n        \"--top-k\"\n        \"40\"\n    ];\n  };\n"
    ),
    "/work/nix-config-q7/README.md": "# nix-config-q7\nHosts: mjolnir, roque, clown.\n",
}
BUILD_LOG = (
    "build started\nstep 1 ok\nstep 2 ok\n"
    + "error: phase failed\n" * 3
    + "build finished with 3 errors\n"
)
TOOLS = [
    {"type": "function", "function": {"name": "read", "description": "Read a file from the repository.",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "write", "description": "Write a file (creates parent dirs).",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}},
                       "required": ["path", "content"]}}},
    {"type": "function", "function": {"name": "edit", "description": "Replace old_string with new_string in a file.",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "old_string": {"type": "string"},
                       "new_string": {"type": "string"}}, "required": ["path", "old_string", "new_string"]}}},
    {"type": "function", "function": {"name": "bash", "description": "Run a shell command: ls, cat, git status.",
        "parameters": {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}}},
    {"type": "function", "function": {"name": "grep", "description": "Search for a pattern in the repository.",
        "parameters": {"type": "object", "properties": {"pattern": {"type": "string"}, "path": {"type": "string"}},
                       "required": ["pattern"]}}},
]
TOOL_NAMES = {t["function"]["name"] for t in TOOLS}
READ_ONLY = {"read", "grep"}


def norm_args(a):
    try:
        return json.dumps(json.loads(a or "{}"), sort_keys=True)
    except Exception:
        return json.dumps({"__raw__": a or ""}, sort_keys=True)


class Server:
    def __init__(self, base):
        self.base = base.rstrip("/")

    def post(self, path, body, timeout=3600):
        req = urllib.request.Request(self.base + path, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json",
                                              "Authorization": "Bearer " + API_KEY})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)

    def count_tokens(self, text):
        return len(self.post("/tokenize", {"content": text}, timeout=120)["tokens"])


class VramPoll(threading.Thread):
    def __init__(self, gpu):
        super().__init__(daemon=True)
        self.gpu, self.peak, self._run = gpu, 0, True

    def run(self):
        while self._run:
            try:
                out = subprocess.run(["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits",
                                      "-i", str(self.gpu)], capture_output=True, text=True, timeout=10).stdout.strip()
                self.peak = max(self.peak, int(float(out)))
            except Exception:
                pass
            time.sleep(2)

    def stop(self):
        self._run = False


class Measure:
    def __init__(self, outdir, label):
        self.rows, self.label, self.outdir = [], label, outdir
        os.makedirs(outdir, exist_ok=True)

    def add(self, kind, **kw):
        kw["kind"] = kind
        self.rows.append(kw)
        with open(os.path.join(self.outdir, "%s.jsonl" % self.label), "a") as f:
            f.write(json.dumps(kw) + "\n")

    @staticmethod
    def distinct_ratio(text):
        w = re.findall(r"[A-Za-z0-9_]+", text.lower())
        return round(len(set(w)) / len(w), 3) if w else None

    @staticmethod
    def intra_repeat(content):
        """Repetition INSIDE one completion - the reported doom loop.

        The model re-emits the same tool call in a single generation when the
        tool-call format it produced does not match what the server parses. Returns
        (n_call_markers, max_count_of_any_identical_nonempty_line).
        """
        markers = len(re.findall(r"<tool_call|<function=|<parameter=", content))
        lines = [l.strip() for l in content.splitlines() if len(l.strip()) > 12]
        dup = max(collections.Counter(lines).values()) if lines else 0
        return markers, dup

    @staticmethod
    def loop_events(calls, results):
        """calls/results: parallel lists per turn. One event per streak, counted at the 3rd."""
        events = []
        for kind, seq in (("same_call", calls), ("same_result", results)):
            if kind == "same_result":
                seq = [r for r, c in zip(results, calls) if c[0] in READ_ONLY]
            streak, prev = 0, None
            for item in seq:
                if item == prev:
                    streak += 1
                    if streak == 3:
                        events.append(kind)
                else:
                    streak = 1
                prev = item
        return events


def gen(server, messages, max_tokens=64, temperature=0.0, seed=42, thinking=False, extra=None):
    body = {"model": "sbx", "messages": messages, "max_tokens": max_tokens,
            "temperature": temperature, "seed": seed,
            "chat_template_kwargs": {"enable_thinking": bool(thinking)}}
    if extra:
        body.update(extra)
    t0 = time.time()
    r = server.post("/v1/chat/completions", body)
    wall = time.time() - t0
    ch = (r.get("choices") or [{}])[0]
    msg = ch.get("message") or {}
    u = r.get("usage") or {}
    ti = r.get("timings") or {}
    det = u.get("prompt_tokens_details") or {}
    return {
        "content": msg.get("content") or "",
        "reasoning": msg.get("reasoning_content") or "",
        "tool_calls": msg.get("tool_calls") or [],
        "finish": ch.get("finish_reason"),
        "prompt_tokens": u.get("prompt_tokens"),
        "completion_tokens": u.get("completion_tokens"),
        "cached_tokens": det.get("cached_tokens") or ti.get("cache_n_tokens"),
        "pp_tps": ti.get("prompt_per_second"),
        "tg_tps": ti.get("predicted_per_second"),
        "draft_n": ti.get("draft_n"),
        "draft_accept": ti.get("draft_avg_accept_rate"),
        "wall_s": round(wall, 2),
    }


def exec_tool(fs, name, args):
    p = args.get("path") or ""
    if name == "read":
        if p in fs:
            return fs[p]
        if p in BUILD_LOG_PATHS:
            return BUILD_LOG
        return "Error: file not found: %s" % p
    if name == "write":
        fs[p] = args.get("content", "")
        return "ok: wrote %d bytes to %s" % (len(fs[p]), p)
    if name == "edit":
        if p not in fs:
            return "Error: file not found: %s" % p
        old, new = args.get("old_string", ""), args.get("new_string", "")
        if old not in fs[p]:
            return "Error: old_string not found in %s" % p
        fs[p] = fs[p].replace(old, new, 1)
        return "ok: edited %s" % p
    if name == "grep":
        pat, scope = args.get("pattern", ""), args.get("path")
        hits = ["%s:%d:%s" % (f, i + 1, ln) for f, c in fs.items() if (not scope or scope in f)
                for i, ln in enumerate(c.splitlines()) if pat in ln]
        return "\n".join(hits) if hits else "No matches found"
    if name == "bash":
        cmd = args.get("command", "")
        if cmd.strip() in ("ls", "ls " + IDENT["cwd"]):
            return "README.md\nmodules\nnotes"
        if cmd.strip().startswith("git status"):
            return "On branch %s\nnothing to commit, working tree clean" % IDENT["branch"]
        if cmd.strip().startswith("cat"):
            return "cat: unknown command in sandbox"
        return "sh: %s: command not found" % cmd.split()[0] if cmd.strip() else "sh: empty command"
    return "Error: unknown tool %s" % name


BUILD_LOG_PATHS = {IDENT["cwd"] + "/notes/build-9f3c.log"}

SCENARIOS = [
    {"id": "explore", "max_turns": 8, "thinking": True, "max_tokens": 1536,
     "user": "In {cwd}, read modules/services/llama-fleet.nix and modules/hosts/mjolnir/"
             "_llama-models.nix, then write a two-line summary of the GPU/port assertions to "
             "notes/summary-q7.md, then run `git status` with bash. Say DONE when finished.".format(**IDENT)},
    {"id": "failing_edit", "max_turns": 6, "thinking": True, "max_tokens": 1536,
     "user": "In {cwd}, change the --temp value in modules/hosts/mjolnir/_llama-models.nix from "
             "0.8 to 0.7. Do not change anything else.".format(**IDENT)},
    {"id": "planted_path", "max_turns": 4, "thinking": True, "max_tokens": 1024,
     "user": "Read the file at {cwd}/notes/build-9f3c.log and tell me how many errors it reports."
             "The file is exactly at that path.".format(**IDENT)},
]


LONGPREFIX = ""


def run_tools(server, m, greedy=False):
    tot = {"calls": 0, "valid": 0, "parse_fail": 0, "bad_name": 0, "path_expected": 0, "path_ok": 0,
           "loops": [], "turns": 0, "tg": [], "max_markers": 0, "max_dup_lines": 0}
    for sc in SCENARIOS:
        fs = dict(FS0)
        sys_txt = SYSTEM if not LONGPREFIX else (
            SYSTEM + "\n\n--- earlier turns of this session (already happened) ---\n"
            + LONGPREFIX + "\n--- end of earlier turns ---")
        msgs = [{"role": "system", "content": sys_txt}, {"role": "user", "content": sc["user"]}]
        calls, results = [], []
        for _turn in range(sc["max_turns"]):
            extra = {"tools": TOOLS, "tool_choice": "auto", "parallel_tool_calls": False}
            try:
                r = gen(server, msgs, max_tokens=sc["max_tokens"],
                        temperature=0.0 if greedy else 0.8, thinking=sc["thinking"], extra=extra)
            except urllib.error.HTTPError as e:
                # A 500 from the tool parser still carries the runaway generation in its
                # message - that is where the doom loop is visible, so measure it there.
                body = e.read().decode("utf8", "replace")[:40000]
                mk, dup = Measure.intra_repeat(body)
                if mk >= 3 or dup >= 3:
                    tot["loops"].append("http_error_runaway")
                tot["max_markers"] = max(tot["max_markers"], mk)
                tot["max_dup_lines"] = max(tot["max_dup_lines"], dup)
                m.add("http_error", scenario=sc["id"], greedy=greedy, status=e.code,
                      markers=mk, dup_lines=dup, body_head=body[:300])
                break
            tot["turns"] += 1
            if r["tg_tps"]:
                tot["tg"].append(r["tg_tps"])
            tc = r["tool_calls"]
            content = r["content"]
            markers, dup = Measure.intra_repeat(content)
            if markers >= 3 or dup >= 3:
                tot["loops"].append("intra_completion_repeat")
            tot["max_markers"] = max(tot["max_markers"], markers)
            tot["max_dup_lines"] = max(tot["max_dup_lines"], dup)
            parse_fail = bool(re.search(r"<function=|<\|tool_call|<parameter=", content))
            if not tc:
                tot["parse_fail"] += 1 if parse_fail else 0
                m.add("tool_turn", scenario=sc["id"], greedy=greedy, calls=[], text_head=content[:200],
                      markers=markers, dup_lines=dup,
                      parse_fail=parse_fail, finish=r["finish"], tg_tps=r["tg_tps"],
                      prompt_tokens=r["prompt_tokens"], completion_tokens=r["completion_tokens"],
                      reasoning_tokens=len(r["reasoning"].split()),
                      distinct=Measure.distinct_ratio(content + " " + r["reasoning"]))
                break
            names = [c.get("function", {}).get("name") for c in tc]
            if any(n not in TOOL_NAMES for n in names):
                tot["bad_name"] += 1
            tot["valid"] += 1
            tot["calls"] += len(tc)
            for c in tc:
                fn = c.get("function", {})
                args = norm_args(fn.get("arguments"))
                calls.append((fn.get("name"), args))
                res = exec_tool(fs, fn.get("name"), json.loads(args))
                results.append(res)
                if sc["id"] == "planted_path" and fn.get("name") == "read":
                    tot["path_expected"] += 1
                    tot["path_ok"] += 1 if json.loads(args).get("path") in BUILD_LOG_PATHS else 0
                m.add("tool_call", scenario=sc["id"], greedy=greedy, name=fn.get("name"), args=args[:400],
                      result_head=res[:160], result_len=len(res), tg_tps=r["tg_tps"], markers=markers,
                      dup_lines=dup, draft_n=r["draft_n"], draft_accept=r["draft_accept"])
            ids = [c.get("id") or "call_%d_%d" % (_turn, i) for i, c in enumerate(tc)]
            msgs.append({"role": "assistant", "content": content or "",
                         "tool_calls": [{"id": ids[i], "type": "function", "function": c.get("function", {})}
                                        for i, c in enumerate(tc)]})
            for i, c in enumerate(tc):
                msgs.append({"role": "tool", "tool_call_id": ids[i], "content": results[i]})
        tot["loops"].extend(Measure.loop_events(calls, results))
    tot["tg"] = round(statistics.mean(tot["tg"]), 2) if tot["tg"] else None
    tot["loops"] = tot["loops"]
    m.add("tools_summary", **tot)
    return tot


def fit_prefix(server, corpus, target_tokens):
    """Longest prefix of `corpus` whose token count is <= target (binary search on chars).

    Monotone prefixes keep the KV prefix reusable across depths: probing 20k then 50k
    re-prefills only the delta, so one arm costs target_max tokens, not sum(targets).
    """
    lo, hi = 0, len(corpus)
    if server.count_tokens(corpus) < target_tokens:
        return corpus, server.count_tokens(corpus)
    while hi - lo > 150:
        mid = (lo + hi) // 2
        n = server.count_tokens(corpus[:mid])
        if n <= target_tokens:
            lo = mid
        else:
            hi = mid
    n = server.count_tokens(corpus[:lo])
    return corpus[:lo], n


def run_ladder(server, m, depths, gpu):
    poll = VramPoll(gpu)
    poll.start()
    needle_at = CORPUS.find(NEEDLE_ID)
    ladder = []
    for target in depths:
        prefix, ptok = fit_prefix(server, CORPUS, target - 200)
        needle_present = 0 <= needle_at < len(prefix)
        depth_row = {"target": target, "corpus_tokens": ptok, "needle_in_context": needle_present, "probes": {}}
        for pid, question, expected in PROBES:
            if pid.startswith("needle") and not needle_present:
                continue  # not scorable at this depth - the needle is not in the prompt
            user = (prefix + "\n\n--- END OF CONTEXT ---\nQuestion: " + question) if prefix else question
            r = gen(server, [{"role": "system", "content": SYSTEM}, {"role": "user", "content": user}],
                    max_tokens=96, temperature=0.0)
            reply = (r["content"] or "").strip()
            ok = expected.lower() in reply.lower()
            depth_row["probes"][pid] = {"ok": ok, "answer": reply[:160], "prompt_tokens": r["prompt_tokens"],
                                        "cached": r["cached_tokens"], "tg_tps": r["tg_tps"],
                                        "finish": r["finish"]}
            m.add("probe", depth=target, probe=pid, ok=ok, answer=reply[:200],
                  prompt_tokens=r["prompt_tokens"], cached=r["cached_tokens"],
                  tg_tps=r["tg_tps"], finish=r["finish"])
        correct = sum(1 for p in depth_row["probes"].values() if p["ok"])
        depth_row["score"] = "%d/%d" % (correct, len(depth_row["probes"]))
        ladder.append(depth_row)
    poll.stop()
    m.add("ladder_summary", ladder=ladder, peak_vram_mib=poll.peak)
    return ladder, poll.peak


CORPUS = None


def corpus_prefix(text, n):
    return text[:n]


def main():
    global CORPUS, LONGPREFIX
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--outdir", default="/var/lib/llama-quality")
    ap.add_argument("--gpu", type=int, default=1)
    ap.add_argument("--corpus", default="/var/lib/llama-quality/corpus.txt")
    ap.add_argument("--depths", default="2000,20000,50000,80000")
    ap.add_argument("--skip-ladder", action="store_true")
    ap.add_argument("--tools-only", action="store_true")
    ap.add_argument("--long-tokens", type=int, default=0,
                    help="prefix the tool suite with N tokens of simulated earlier turns "
                         "(tests whether the model can see what it already did)")
    ap.add_argument("--greedy-tools", action="store_true",
                    help="also run the tool suite at temperature 0 (deterministic sub-suite)")
    a = ap.parse_args()
    m = Measure(a.outdir, a.label)
    server = Server(a.base)
    for _ in range(60):
        try:
            server.post("/tokenize", {"content": "x"}, timeout=30)
            break
        except Exception:
            time.sleep(5)
    global LONGPREFIX
    with open(a.corpus) as f:
        CORPUS = f.read()
    if a.long_tokens:
        LONGPREFIX, n = fit_prefix(server, CORPUS, a.long_tokens)
        m.add("long_prefix", tokens=n, chars=len(LONGPREFIX))
    if a.skip_ladder or a.tools_only:
        ladder, peak = [], None
    else:
        depths = [int(x) for x in a.depths.split(",")]
        ladder, peak = run_ladder(server, m, depths, a.gpu)
    tools = run_tools(server, m)
    if a.greedy_tools:
        g = run_tools(server, Measure(a.outdir, a.label + "_greedy"), greedy=True)
        m.add("tools_greedy_summary", **g)
    summary = {"label": a.label, "ladder": ladder, "peak_vram_mib": peak, "tools": tools}
    with open(os.path.join(a.outdir, "%s.summary.json" % a.label), "w") as f:
        json.dump(summary, f, indent=2)
    print(json.dumps({"label": a.label, "ladder_scores": [d["score"] for d in ladder],
                      "peak_vram_mib": peak, "tools_valid": "%d/%d" % (tools["valid"], tools["turns"]),
                      "tool_calls": tools["calls"], "bad_name": tools["bad_name"],
                      "parse_fail": tools["parse_fail"], "loops": tools["loops"],
                      "path": "%d/%d" % (tools["path_ok"], tools["path_expected"]),
                      "tg_tps": tools["tg"]}, indent=2))


main()
