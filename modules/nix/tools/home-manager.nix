{ inputs, ... }:
{
  flake.modules.nixos.home-manager-integration = {
    imports = [ inputs.home-manager.nixosModules.home-manager ];

    home-manager = {
      useGlobalPkgs = true;
      backupFileExtension = "bak";
    };
  };
}
