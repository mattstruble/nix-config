{ config
, lib
, pkgs
, inputs
, ...
}:
let
  extraHomeManagerImports = [
    inputs.sops-nix.homeManagerModules.sops
  ];
in
{

  users.users = {
    root = {
      initialHashedPassword = config.sops.secrets."users/root/password".path;
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
    useGlobalPkgs = false;
    extraSpecialArgs = { inherit inputs; };
    users.mestruble.imports = [
      ./mestruble/home.nix
    ]
    ++ extraHomeManagerImports;
  };
}
