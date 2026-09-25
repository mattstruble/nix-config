{ inputs, ... }:
{
  flake.modules.nixos.autoaspm = {
    imports = [ inputs.autoaspm.nixosModules.default ];
    services.autoaspm.enable = true;
  };
}
