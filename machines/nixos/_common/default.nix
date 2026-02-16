{ config
, pkgs
, lib
, ...
}:
{

  imports = [
    ./basics.nix
    ./packages.nix
    ./services.nix
    ./networking.nix
    ../../../users
  ];

}
