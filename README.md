# nix-config

Declarative config for my NixOS cluster. One repo, two deployable surfaces:

- **`nix/`** — NixOS host configurations (mjolnir, roque, and the rpi cluster),
  built and deployed via flake + deploy-rs.
- **`k8s/`** — Helm charts + cluster manifests for the k3s AI fleet that runs on
  mjolnir. See [k8s/README.md](k8s/README.md).

## Layout

```
├── nix/            # NixOS configuration (import-tree auto-discovers this)
│   ├── hosts/      # one dir per host: mjolnir/, roque/ + rpi-cluster.nix
│   ├── modules/    # shared NixOS modules (system/, services/, users/, ...)
│   ├── users/      # per-user modules
│   └── nix/        # nix/nixpkgs settings, overlays, secrets, tools (deploy.nix)
├── k8s/            # k3s cluster on mjolnir (charts + manifests + values)
├── patches/        # source patches (nixpkgs, llama.cpp, ...)
├── docs/           # design docs + research notes
├── flake.nix       # flake-parts + import-tree; nixosConfigurations + deploy
└── justfile        # deploy + k8s + lint tasks
```

Files prefixed with `_` (e.g. `hosts/roque/_hardware-configuration.nix`) are
excluded from import-tree auto-discovery — use that prefix for host-local helper
files that shouldn't become modules.

## Deploy

- `just deploy <host>` — build the host's system and deploy via deploy-rs
  (e.g. `just deploy mjolnir`). Hosts are declared in
  `nix/nix/tools/deploy.nix`.
- `just k8s-deploy` — render the ai chart and apply it to mjolnir's k3s (fast
  manual path, no nix build).
- `just k8s-render` — render the ai chart to stdout (dry run).
- `just lint` — pre-commit (nixfmt, etc.).

`just deploy mjolnir` also applies `k8s/manifests/` and renders the ai chart via
the k3s.nix post-activation hook, so one deploy covers host config + cluster.

## Runbook: add a new NixOS host

1. Create `nix/hosts/<name>/default.nix`. It registers the configuration and
   defines the host module (copy `roque/default.nix` as a starting point):

   ```nix
   { inputs, ... }:
   {
     # arch: "x86_64-linux" (servers) or "aarch64-linux" (rpi)
     flake.nixosConfigurations = inputs.self.lib.mkNixos "x86_64-linux" "<name>";

     flake.modules.nixos.<name> =
       { pkgs, ... }:
       {
         imports =
           (with inputs.self.modules.nixos; [
             tier-server
             # ... other shared modules
           ])
           ++ [ ./_hardware-configuration.nix ];

         networking.hostName = "<name>";
         system.stateVersion = "25.05";
       };
   }
   ```

   import-tree picks up the new host automatically — no flake.nix edit needed.

2. Add a deploy target in `nix/nix/tools/deploy.nix`:
   `nodes.<name> = mkDeploy "<name>" "<arch>";`

3. `just deploy <name>`.

For an rpi host, instead add its name to the `rpiHosts` list in
`nix/hosts/rpi-cluster.nix` (which auto-generates the module + configuration)
and it will also be covered by `just build-rpi-images`.

## Runbook: add a new k8s app / model

**New model in the ai fleet** (most common): add one
`k8s/apps/ai/values/<model>.yaml` with the model's `image`, `gpu`, `resources`,
and `enable`. The chart renders a Deployment + Service and adds it to the
LiteLLM gateway. Follow the conventions in [k8s/README.md](k8s/README.md)
(digest-pin, GPU pinning, PSS restricted, resource limits). Then `just k8s-deploy`.

**New app domain**: create `k8s/apps/<domain>/` as a standalone Helm chart
(`Chart.yaml`, `templates/`, `values.yaml`). Render it with `helm template`, then
ship it via `k8s/manifests/` (auto-applied at node start) or a post-activation
hook like `nix/modules/services/k3s.nix`.

## References

This repository wouldn't be possible without the help of numerous articles,
YouTube videos, and forum posts. Below is a non-exhaustive list of the ones
I've been able to keep track of.

- [notthebee/nix-config](https://github.com/notthebee/nix-config) and the
  [related youtube video](https://youtube.com/watch?v=f-x5cB6qCzA)
- [lgug2z handling-secrets-in-nixos-an-overview](https://lgug2z.com/articles/handling-secrets-in-nixos-an-overview/)
- [tsawyer87 sops-nix secrets](https://tsawyer87.github.io/posts/sops-nix/)
- [samleathers](https://samleathers.com/posts/2022-02-11-my-new-network-and-sops.html)
- [LongerHV nixos-configuration](https://github.com/LongerHV/nixos-configuration)
- [janissary nixos-install-custom-image](https://blog.janissary.xyz/posts/nixos-install-custom-image)
