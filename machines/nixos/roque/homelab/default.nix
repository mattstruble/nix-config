{ config
, inputs
, pkgs
, lib
, ...
}:
{
  services = {
    plex.enable = true;
    pulseaudio.enable = true;
  };

  networking.firewall.allowedTCPPorts = [ 32400 ]; # Allow Plex port
  networking.firewall.allowedUDPPorts = [ 32400 ]; # Allow Plex port
}
