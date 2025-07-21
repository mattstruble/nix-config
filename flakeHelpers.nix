# Borrowed heavily from https://github.com/notthebee/nix-config/blob/main/flakeHelpers.nix
inputs:
let
  homeManagerCfg = userPackages: extraImports: {
    home-manager.useGlobalPkgs = false;
    home-manager.extraSpecialArgs = {
      inherit inputs;
    };
    home-manager.users.mestruble.imports = [
      inputs.sops-nix.homeManagerModules.sops
      ./users/mestruble/dots.nix
    ] ++ extraImports;
    home-manager.backupFileExtension = "bak";
    home-manager.useUserPackages = userPackages;
  };
in
{
  mkNixos = machineHostname: nixpkgsVersion: extraModules: rec {
    deploy.nodes.${machineHostname} = {
      hostname = machineHostname;
      profiles.system = {
        user = "root";
        sshUser = "mestruble";
        path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos nixosConfigurations.${machineHostname};
      };
    };
    nixosConfigurations.${machineHostname} = nixpkgsVersion.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        inherit inputs;
      };
      modules = [
	./machines/nixos/${machineHostname}/hardware-configuration.nix
        ./common/sops
        ./machines/nixos/_common
        ./machines/nixos/${machineHostname}
        ./modules/auto-aspm
        inputs.sops-nix.nixosModules.sops
        (homeManagerCfg false [ ])
      ] ++ extraModules;
    };
  };
  mkMerge = inputs.nixpkgs.lib.lists.foldl'
    (
      a: b: inputs.nixpkgs.lib.attrsets.recursiveUpdate a b
    )
    { };
}
