{ inputs, ... }:
{
  flake.modules.nixos.tier-server = {
    imports = with inputs.self.modules.nixos; [
      tier-base
      networking
      ssh
      cli-tools
    ];

    home-manager.sharedModules = with inputs.self.modules.homeManager; [
      shell
      neovim
    ];
  };
}
