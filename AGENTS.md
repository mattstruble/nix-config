# AGENTS.md

Rules that are not inferable from the code. Layout, deploy mechanics and
conventions live in `README.md` and `k8s/README.md`.

## What a document may contain

**A document holds intent, and a sequence a human runs by hand. It holds no
description of what this repo's own code, config or manifests already
express.**

It reaches every file in this repo, whatever its path or type — including
this file.

Intent is exactly three things:

- **what must stay true** — an invariant, and what breaks when it does not
  hold;
- **what is deliberately not done** — the cheaper or more obvious alternative
  that was rejected, and on what grounds;
- **a constraint imposed by software outside this repo** — what upstream, a
  runtime, a registry or an identity provider actually does, which CI here
  cannot see, and which is the only reason a line of config exists.

A human-run sequence is the steps a person performs by hand: commands, in
order, with the check that tells them the step worked. Anything automated is
expressed by the automation, not by prose about it.

Where prose restates a fact that code or a test can assert, convert it to the
assertion or delete it. Convert, not shorten: a render that fails, a CI job
that goes red, or a `required` in a template cannot drift, and a sentence
can — silently, on the next change to the thing it describes.

### Applying this to a comment block

Ask of each line: does it name one of the three kinds of intent? A line that
explains what the code below it does is describing this repo, so it does not
belong in what you are writing. A block that survives that question line by
line is a list of external constraints and invariants — and each of those
belongs in one sentence beside the line it constrains, not gathered above it.
So a 40-line comment block does not belong in this repo; 40 separate
one-sentence constraints, each with its own line, do.

### What the rule does not license

It governs prose you write, and prose you are already editing. It is never a
reason to delete a comment an unrelated change walks past: a fix does not come
with a sweep of the file it touched, and a diff that only removes comments is
its own change, with its own review.

When you cannot tell whether an existing line records a constraint CI cannot
see, leave it. Those lines are what the rule protects, and they are the ones a
fast reader misreads as explaining the code below — a comment beside a
`kubectl apply --prune` loop that says why two passes cannot share a selector,
or beside a Pod Security exception that says what was measured, is bloat only
until someone deletes it and the next change breaks it.

## What a check may be

The rule above is about prose. This one is about mechanism, and it exists for
the same reason: a check is a document that can drift.

**Discover, do not enumerate.** When a check exists to assert that several
places name the same app, path or number, the fix is the enumeration — one list,
or a `readDir`, that those places are derived from. A check that three
hand-written lists agree is a fourth list to maintain, and it can pass while all
four are wrong.

**A value has one source.** If two files must agree, render one from the other.
A checker for the agreement leaves both files free to drift and adds a third
thing that can be wrong.

**CI validates artifacts; the cluster observes runtime health.** No workflow may
query live external state — DNS, a registry's current digest, a URL's status. A
green run from a GitHub runner is evidence about the runner. A scheduled probe
belongs in the namespace whose policy or resolver is the thing that would fail,
where it can be alerted on.

**Never hand-parse another language in shell.** No `awk` or `sed` parser for
nix, YAML, JSON or GitHub Actions; use `nix eval`, `yq`, `jq`, `helm`. A
reimplemented parser disagrees with the real one on exactly the inputs that
matter, and the disagreement looks like a passing check.

**Generic linters before bespoke checkers.** The generic ones are wired into
`.pre-commit-config.yaml` and cover every file from one config each. A new
`scripts/check-*.sh` asserts one project-specific invariant, carries its own
parser, and drifts.

**A check's comment records the constraint it enforces, and what a green run does
not claim — once, in a sentence.** Not the history of what it replaced, not a
defence of its design, not a narration of its own parsing.

## Why it exists

Three review passes ran against PR #304, and in the second,
nine findings were residuals of tickets closed in the first — the fix had
landed and the comment it left behind claimed more than the code does. The
history is `~/llm-wiki/decisions/2026-11-12-documentation-scope-rule.md`.

The rules above came out of the third pass, against the same PR: it shipped four
bespoke checkers and three workflows to validate them, two of which asserted
that values nix could have emitted were equal to each other, one of which
resolved public DNS from a runner and said so in its own header, and all four of
which were shell parsers for other languages. The app they wrapped was smaller
than the scaffolding around it.
