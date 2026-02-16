{ config
, pkgs
, lib
, ...
}:
{
  networking = {
    firewall = {
      enable = true;
      allowPing = true;
    };
    networkmanager.enable = true;
  };
}
