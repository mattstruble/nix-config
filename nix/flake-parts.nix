{ inputs, lib, ... }:
{
  imports = [
    inputs.flake-parts.flakeModules.modules
  ];

  config = {
    systems = [
      # aarch64-darwin is the local build machine that runs `nix run .#deploy-rs`
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-linux"
    ];

    flake.lib = {
      modulesPath = "${inputs.nixpkgs}/nixos/modules";

      # Pocket ID signs the OIDC `iss` claim from its own APP_URL, and every
      # relying party validates `iss` against this exact string. It is read by
      # two hosts that never evaluate together (roque runs the IdP, mjolnir
      # renders the relying party's chart), so it lives here rather than in
      # either of theirs.
      issuerUrl = "https://auth.struble.app";

      mkNixos = system: name: {
        ${name} = inputs.nixpkgs.lib.nixosSystem {
          modules = [
            inputs.self.modules.nixos.${name}
            { nixpkgs.hostPlatform = lib.mkDefault system; }
          ];
        };
      };

    };

  };
}
