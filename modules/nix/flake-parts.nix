{ inputs, lib, ... }:
{
  imports = [
    inputs.flake-parts.flakeModules.modules
  ];

  config = {
    systems = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-darwin"
      "x86_64-linux"
    ];

    flake.lib = {
      modulesPath = "${inputs.nixpkgs}/nixos/modules";

      mkNixos = system: name: {
        ${name} = inputs.nixpkgs.lib.nixosSystem {
          modules = [
            inputs.self.modules.nixos.${name}
            { nixpkgs.hostPlatform = lib.mkDefault system; }
          ];
        };
      };

      mkDarwin = system: name: {
        ${name} = inputs.nix-darwin.lib.darwinSystem {
          modules = [
            inputs.self.modules.darwin.${name}
            { nixpkgs.hostPlatform = lib.mkDefault system; }
          ];
        };
      };
    };

    flake.darwinConfigurations =
      (inputs.self.lib.mkDarwin "aarch64-darwin" "MacStruble")
      // (inputs.self.lib.mkDarwin "aarch64-darwin" "lm-mstruble");
  };
}
