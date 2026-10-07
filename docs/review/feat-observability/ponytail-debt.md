# Ponytail Debt Ledger

Debt markers (`ponytail:` comments) harvested from the repo, grouped by file.
`no-trigger` = the marker names no upgrade path/trigger — highest rot risk.

## nix/hosts/mjolnir/_disko.nix

- `nix/hosts/mjolnir/_disko.nix:6`, disk device hardcoded to a single NVMe (`/dev/nvme0n1`). ceiling: single NVMe per system spec. upgrade: verify via `lsblk` before install.

## nix/hosts/mjolnir/default.nix

- `nix/hosts/mjolnir/default.nix:27`, boot entries capped at 3 systemd-boot generations after unlimited entries (one ~180MB initrd per generation) filled the 1GB `/boot` and broke deploys on 2026-09-18. ceiling: 3 boot generations on a 1GB `/boot` partition. upgrade: none named. [no-trigger]
- `nix/hosts/mjolnir/default.nix:36`, Nix build cores capped at 8. ceiling: 8 cores (64 cores exhausts 96GB RAM during CUDA/Cython C++ compilation). upgrade: none named. [no-trigger]
- `nix/hosts/mjolnir/default.nix:39`, 32G swapfile added as a band-aid for compilation OOMs. ceiling: 32G swapfile absorbing CUDA compilation memory spikes (nvcc cicc). upgrade: none named. [no-trigger]

## nix/services/homelab/homelab.nix

- `nix/services/homelab/homelab.nix:23`, insecure package `pnpm-9.15.9` permitted for the karakeep build. ceiling: build-time only. upgrade: remove when nixpkgs bumps karakeep off `pnpm_9`.

## nix/services/k3s.nix

- `nix/services/k3s.nix:17`, chart rendering hardcodes the single `ai` chart. ceiling: one chart hardcoded. upgrade: generalize to a chart list when a second app lands.

---

6 markers, 3 with no trigger.
