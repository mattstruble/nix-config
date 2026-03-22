{ inputs, lib, ... }:
let
  rpiHosts = [ "sevro" "thistle" "pebble" "clown" ];

  mkRpiModules = name: {
    ${name} = {
      imports = with inputs.self.modules.nixos; [
        nix-settings
        security
        networking
        packages
        ssh
        sops
        users
        rpi-hardware
      ];

      networking.hostName = name;
      system.stateVersion = "25.05";
    };
  };

in
{
  flake.modules.nixos = lib.mkMerge (map mkRpiModules rpiHosts);
  flake.nixosConfigurations = lib.mkMerge (map (name: inputs.self.lib.mkNixos "aarch64-linux" name) rpiHosts);
}
