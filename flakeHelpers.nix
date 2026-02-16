# Borrowed heavily from https://github.com/notthebee/nix-config/blob/main/flakeHelpers.nix
inputs: {
  mkNixos = machineHostname: nixpkgsVersion: extraModules: rec {
    deploy.magicRollback = true;
    deploy.remoteBuild = true;
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
        ./common/sops
        ./machines/nixos/_common
        ./machines/nixos/${machineHostname}
        ./users
        inputs.sops-nix.nixosModules.sops
      ]
      ++ extraModules;
    };
  };
  mkMerge = inputs.nixpkgs.lib.lists.foldl'
    (
      a: b: inputs.nixpkgs.lib.attrsets.recursiveUpdate a b
    )
    { };
}
