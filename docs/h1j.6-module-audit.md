# Module Audit (h1j.6)

**Summary:** 37 files (~2300 lines) audited. Verdicts: 22 keep, 11 delete, 3 trim, 1 split. The tier layer (`base.nix`, `server.nix`) is pure indirection—every host imports `tier-server`, so flatten into direct imports. The biggest wins are deleting 5 dead homeManager modules (~646 lines) and 3 dead host-specific files (~176 lines).

| file | lines | partition(s) | consumer? | verdict | rationale |
|---|---|---|---|---|---|
| `nix/devshell.nix` | 15 | flake | flake outputs | KEEP | Dev shell definition. |
| `nix/hardware/autoaspm.nix` | 7 | nixos | roque | KEEP | Single-concern hardware enable. |
| `nix/hardware/intel.nix` | 25 | nixos | roque | KEEP | Intel GPU/VAAPI firmware. |
| `nix/hardware/nvidia.nix` | 42 | nixos | mjolnir | KEEP | NVIDIA modesetting + CUDA caps. |
| `nix/hardware/rpi.nix` | 48 | nixos | rpi-cluster | KEEP | Raspberry Pi SD image + boot. |
| `nix/hosts/mjolnir/_disko.nix` | 41 | nixos | none | DELETE | Unused disko layout; no host imports it. |
| `nix/hosts/mjolnir/_hardware-configuration.nix` | 31 | nixos | mjolnir | KEEP | Auto-generated hardware scan. |
| `nix/hosts/mjolnir/_llama-fork.nix` | 70 | derivation | none | DELETE | Unreferenced CUDA derivation. |
| `nix/hosts/mjolnir/_llama-turboq.nix` | 65 | derivation | none | DELETE | Unreferenced CUDA derivation. |
| `nix/hosts/mjolnir/_locale.nix` | 21 | nixos | mjolnir | KEEP | Locale/keymap for host. |
| `nix/hosts/mjolnir/default.nix` | 123 | host | flake | KEEP | Host entry + k3s/nvidia specifics. |
| `nix/hosts/roque/_hardware-configuration.nix` | 29 | nixos | roque | KEEP | Auto-generated hardware scan. |
| `nix/hosts/roque/_locale.nix` | 21 | nixos | roque | KEEP | Locale/keymap for host. |
| `nix/hosts/roque/default.nix` | 43 | host | flake | KEEP | Host entry + homelab specifics. |
| `nix/hosts/rpi-cluster.nix` | 21 | host | flake | KEEP | Shared RPi host definitions. |
| `nix/nix/flake-parts.nix` | 28 | flake | flake | KEEP | Core flake-parts scaffolding. |
| `nix/nix/tools/deploy.nix` | 35 | flake | flake | KEEP | deploy-rs node definitions. |
| `nix/nix/tools/disko.nix` | 6 | nixos | none | DELETE | Dead wrapper; no host imports `disko`. |
| `nix/nix/tools/home-manager.nix` | 11 | nixos | tier-base | KEEP | home-manager nixos module import. |
| `nix/nix/tools/sops.nix` | 12 | nixos | tier-base | KEEP | sops-nix nixos module import. |
| `nix/programs/ai-agents.nix` | 98 | homeManager | none | DELETE | Dead darwin-only module. |
| `nix/programs/browser.nix` | 239 | homeManager | none | DELETE | Dead darwin-only module. |
| `nix/programs/cli-tools.nix` | 175 | nixos+homeManager | tier-server (nixos) | TRIM | NixOS half live; homeManager half dead. Remove dead half. |
| `nix/programs/dev-tools.nix` | 94 | homeManager | none | DELETE | Dead darwin-only module (3 isDarwin). |
| `nix/programs/git.nix` | 192 | homeManager | none | DELETE | Dead darwin-only module (1Password SSH sign path). |
| `nix/programs/neovim.nix` | 19 | homeManager | tier-server | KEEP | Live; dotfile symlink only. |
| `nix/programs/shell.nix` | 275 | homeManager | tier-server | TRIM | Live shell config; 10 dead isDarwin branches. |
| `nix/programs/workstation.nix` | 23 | homeManager | none | DELETE | Dead darwin-only dotfile links. |
| `nix/services/homelab/homelab.nix` | 171 | nixos | roque | SPLIT | Grab-bag: media, automation, identity, VPN, NFS. Split into per-concern files. |
| `nix/services/k3s.nix` | 97 | nixos | mjolnir | KEEP | Single-concern k3s + nvidia runtime. |
| `nix/services/ssh.nix` | 64 | nixos+homeManager | tier-server (nixos) | TRIM | NixOS half live; homeManager `ssh-client` dead. Remove dead half. |
| `nix/system/nix-settings.nix` | 45 | nixos | tier-base | KEEP | Nix daemon, GC, auto-upgrade. |
| `nix/system/settings/networking.nix` | 12 | nixos | tier-server | KEEP | Firewall + NetworkManager baseline. |
| `nix/system/settings/security.nix` | 22 | nixos | tier-base | KEEP | sudo/doas baseline. |
| `nix/system/tiers/base.nix` | 12 | nixos | tier-server | DELETE | Middle layer; flatten into hosts. |
| `nix/system/tiers/server.nix` | 16 | nixos | all hosts | DELETE | Middle layer; flatten into hosts. |
| `nix/users/mestruble.nix` | 55 | nixos+homeManager | tier-base / user-mestruble | KEEP | Both halves live; user definition. |

## Execution Plan

1. **Delete dead homeManager modules** (~646 lines, 5 files)
   - Remove `nix/programs/ai-agents.nix`, `nix/programs/browser.nix`, `nix/programs/dev-tools.nix`, `nix/programs/git.nix`, `nix/programs/workstation.nix`.

2. **Delete dead host-specific files** (~176 lines, 3 files)
   - Remove `nix/hosts/mjolnir/_disko.nix`, `nix/hosts/mjolnir/_llama-fork.nix`, `nix/hosts/mjolnir/_llama-turboq.nix`.

3. **Delete dead tool wrapper** (6 lines, 1 file)
   - Remove `nix/nix/tools/disko.nix`.

4. **Trim mixed-partition files** (~200 lines removed, 3 files)
   - `nix/programs/cli-tools.nix`: delete the entire `flake.modules.homeManager.cli-tools` block.
   - `nix/services/ssh.nix`: delete the entire `flake.modules.homeManager.ssh-client` block.
   - `nix/programs/shell.nix`: delete all `isDarwin` branches (`programs.bash`, `lib.optionalAttrs isDarwin` in sessionVariables, `lib.optionalString isDarwin` in profileExtra, `lib.mkIf isDarwin` in initContent, darwin-only `home.sessionPath` entries, `news.display`, `home.enableNixpkgsReleaseCheck`, `targets.darwin`).

5. **Flatten tiers** (2 files deleted, 3 host files updated)
   - Delete `nix/system/tiers/base.nix` and `nix/system/tiers/server.nix`.
   - In `nix/hosts/mjolnir/default.nix`, `nix/hosts/roque/default.nix`, and `nix/hosts/rpi-cluster.nix`, replace the `tier-server` import with explicit imports of its former members:
     `home-manager-integration`, `nix-settings`, `security`, `secrets`, `user-mestruble`, `networking`, `ssh`, `cli-tools`.
   - Add `home-manager.sharedModules = [ shell neovim ];` to each of the three host definitions.

6. **Split `nix/services/homelab/homelab.nix`** (~171 lines moved, 1 host updated)
   - Create per-concern modules under `nix/services/homelab/`:
     - `media.nix` — plex, immich, seerr, nginx reverse-proxy for immich
     - `automation.nix` — n8n
     - `identity.nix` — pocket-id (with its static UID/GID)
     - `bookmarks.nix` — karakeep (with its static UID/GID)
     - `vpn.nix` — tailscale + firewall rules
     - `storage.nix` — NFS mounts (`/mnt/media`, `/mnt/immich`, `/mnt/pocket-id`)
   - Update `nix/hosts/roque/default.nix` to import these directly instead of the monolithic `homelab` module.

## Approved plan (2026-09-24, user decisions)

The audit's recommendations above were reviewed. Final approved scope for h1j.7:

**DO:**
1. Delete 5 dead darwin-only homeManager modules: `nix/programs/{ai-agents,browser,dev-tools,git,workstation}.nix` (~646 lines).
2. Delete `nix/nix/tools/disko.nix` (6-line dead wrapper).
3. Trim `nix/programs/cli-tools.nix` — delete the dead `flake.modules.homeManager.cli-tools` block (keep the live `nixos` half).
4. Trim `nix/services/ssh.nix` — delete the dead `flake.modules.homeManager.ssh-client` block (keep the live `nixos` half).
5. Trim `nix/programs/shell.nix` — delete all 10 dead `isDarwin` branches.

**KEEP (audit recommended change, user overrode):**
- `nix/services/homelab/homelab.nix` — stays whole. Cohesive single-host stack; none of the split values (independent toggling / sharing / find-pain) clear the bar.
- `nix/system/tiers/{base,server}.nix` — stay. Host profiles, not feature grab-bags; flattening adds ~30 lines of duplication across 3 hosts.
- `nix/hosts/mjolnir/{_llama-fork,_llama-turboq,_disko}.nix` — stay. Orphaned from the live graph (current k8s fleet uses ghcr images) but are fork build recipes / a saved disk layout; keep for now.
