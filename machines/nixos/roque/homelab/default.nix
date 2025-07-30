{ config
, inputs
, pkgs
, lib
, ...
}:
{
  services = {
    plex.enable = true;
  };

  hardware.enableAllFirmware = true;
  hardware.pulseaudio.enable = true;

  networking.firewall.allowedTCPPorts = [ 32400 ]; # Allow Plex port
  networking.firewall.allowedUDPPorts = [ 32400 ]; # Allow Plex port

  users.users.plex = {
    isNormalUser = true;
    home = "/var/lib/plex";
    shell = pkgs.bash;
  };
}
