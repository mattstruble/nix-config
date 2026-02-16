{ ... }:
{
  networking.useDHCP = true;
  networking.firewall.enable = true;

  services.timesyncd.enable = true;
}
