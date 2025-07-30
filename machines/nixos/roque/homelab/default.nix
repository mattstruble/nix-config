{ config
, inputs
, pkgs
, lib
, ...
}:
{
  services = {
    plex = {
      enable = true;
      openFirewall = true;
    };
    pulseaudio.enable = true;
  };

}
