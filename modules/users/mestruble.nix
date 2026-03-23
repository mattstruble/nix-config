{ inputs, ... }:
{
  flake.modules.nixos.user-mestruble =
    { config, ... }:
    {
      sops = {
        defaultSopsFile = ./sops-secrets.yaml;
        secrets = {
          "users/mestruble/password" = {
            neededForUsers = true;
          };
          "users/root/password" = {
            neededForUsers = true;
          };
        };
      };

      users.users = {
        root = {
          hashedPasswordFile = config.sops.secrets."users/root/password".path;
        };
        mestruble = {
          isNormalUser = true;
          hashedPasswordFile = config.sops.secrets."users/mestruble/password".path;
          description = "Matt Struble";
          extraGroups = [
            "networkmanager"
            "wheel"
          ];
          openssh.authorizedKeys.keys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEL+QzypEEYDWtg6jJ1siaNho4ZdwsczWwTZWySAZdkm"
          ];
        };
      };

      home-manager = {
        sharedModules = with inputs.self.modules.homeManager; [
          user-base
        ];
        users.mestruble.imports = [
          inputs.sops-nix.homeManagerModules.sops
        ];
      };
    };

  flake.modules.homeManager.user-base =
    { pkgs, ... }:
    {
      home = {
        stateVersion = "23.11";
        username = "mestruble";
        homeDirectory =
          if pkgs.stdenv.isDarwin
          then "/Users/mestruble"
          else "/home/mestruble";
      };
    };
}
