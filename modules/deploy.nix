{ inputs, ... }:
let
  mkDeploy = hostname: arch: {
    hostname = hostname;
    profiles.system = {
      user = "root";
      sshUser = "mestruble";
      path = inputs.deploy-rs.lib.${arch}.activate.nixos
        inputs.self.nixosConfigurations.${hostname};
    };
  };
in
{
  flake.deploy = {
    magicRollback = true;
    remoteBuild = true;
    nodes = {
      roque = mkDeploy "roque" "x86_64-linux";
      sevro = mkDeploy "sevro" "aarch64-linux";
      thistle = mkDeploy "thistle" "aarch64-linux";
      pebble = mkDeploy "pebble" "aarch64-linux";
      clown = mkDeploy "clown" "aarch64-linux";
    };
  };
}
