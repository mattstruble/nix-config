# Borrowed heavily from https://github.com/notthebee/nix-config/blob/main/flakeHelpers.nix
inputs: {
  mkNixos = machineHostname: nixpkgsVersion: extraModules: arch: rec {
    deploy.magicRollback = true;
    deploy.remoteBuild = true;
    deploy.nodes.${machineHostname} = {
      hostname = machineHostname;
      profiles.system = {
        user = "root";
        sshUser = "mestruble";
        path = inputs.deploy-rs.lib.${arch}.activate.nixos nixosConfigurations.${machineHostname};
      };
    };
    nixosConfigurations.${machineHostname} = nixpkgsVersion.lib.nixosSystem {
      system = arch;
      specialArgs = {
        inherit inputs;
      };
      modules = [
        ./common/sops
        ./users
        ./machines/nixos/${machineHostname}
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
