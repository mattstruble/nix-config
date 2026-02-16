{ lib, ... }:
{
  networking.useDHCP = lib.mkForce true;
  networking.firewall.enable = true;

  services.timesyncd.enable = true;
}
