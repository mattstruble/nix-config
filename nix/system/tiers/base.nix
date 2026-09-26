{ inputs, ... }:
{
  flake.modules.nixos.tier-base = {
    imports = with inputs.self.modules.nixos; [
      home-manager-integration
      nix-settings
      security
      secrets
      user-mestruble
    ];
  };
}
