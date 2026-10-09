# ponytail-debt: `feat/qwen-strata` ledger

Harvested with `grep -rn "ponytail:" .` over the whole tree (`.git`, `result` and this
`docs/review/` tree excluded). Report only — nothing changed.

## nix/hosts/mjolnir/default.nix
- **:27** — boot entries capped at 3 generations instead of unlimited. ceiling: the 1 GB `/boot`
  partition vs ~180 MB initrd per generation. upgrade: no trigger named — it is a permanent cap
  with a dated incident (2026-09-18) behind it; it rots only if `/boot` is resized, and nothing
  will notice if it is. **no-trigger**
- **:36** — `nix.settings.cores = 8` instead of 64. ceiling: 96 GB RAM during CUDA/Cython C++
  compiles. upgrade: implied (raise it when the RAM or a build cache changes), never written.
  **no-trigger**
- **:39** — 32 G swapfile instead of no swap. ceiling: nvcc `cicc` memory spikes. upgrade: implied
  (remove when CUDA builds stop here or move to a builder). **no-trigger**

## nix/hosts/mjolnir/_disko.nix
- **:6** — `device = "/dev/nvme0n1"`, one disk per system. ceiling: single-NVMe layout. upgrade:
  "verify via lsblk before install" is a one-time install step, not a condition that revisits the
  marker. **no-trigger**

## nix/services/homelab/homelab.nix
- **:23** — `permittedInsecurePackages = [ "pnpm-9.15.9" ]`. ceiling: build-time only, not served.
  upgrade: "remove when nixpkgs bumps karakeep off pnpm_9" — checkable, dated by nothing. ✓

## nix/services/k3s.nix
- **:21** — one chart hardcoded in the render derivation instead of a chart list. ceiling: a
  second app domain. upgrade: "generalize to a chart list when a second app lands". ✓
  Note: this marker is mid-comment, not `# ponytail:` at the line start — the audit command's
  regex `(#|//) ?ponytail:` does **not** match it. Grep for bare `ponytail:` or it goes uncounted.

**6 markers; 4 lack an upgrade trigger** (2 of 6 are checkable).

## Markers this branch should have added
Deferrals that are real but invisible to this ledger because they were written as prose:

- `k8s/apps/ai/templates/strata-deployment.yaml` — a 262k-token prefill (~255 s) exceeds the 120 s
  grace period, so long prefills die on rollout. Called a "documented trade-off"; no marker, no
  trigger.
- `k8s/apps/ai/values/flash-next-strata-iq4xs.yaml` — the 2-GPU variant is deferred, and the
  entrypoint fork currently cannot pin `--gpus`/`--layer-split` (upstream repeats them on every
  start; the fork drops them). No marker.
- `k8s/apps/ai/values/gemma-4-26b-a4b.yaml` — gemma disabled to free GPU 1, with a re-enable
  recipe in the comment. This is exactly a `ponytail:`-shaped deferral; it reads as a changelog
  note instead.
- `nix/hosts/mjolnir/default.nix` — the GC root protects only the current generation's bundle, so
  a pod held on an old path can lose it at a later weekly GC. The comment explains the fix it
  chose, not the residual risk it accepted.
- The engine settings (context, KV dtype, resident budget) live in a config JSON on the PVC that
  is not in git. Nothing marks "this state is out-of-band" — the worst kind of debt, since the
  ledger cannot list what the tree does not know about.
