{ inputs, ... }:
{
  flake.modules.nixos.users =
    { config, ... }:
    {
      imports = [ inputs.home-manager.nixosModules.home-manager ];

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
        backupFileExtension = "bak";
        useGlobalPkgs = true;
        sharedModules = with inputs.self.modules.homeManager; [
          user-base
          shell
          neovim
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
