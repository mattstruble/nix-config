{ config
, inputs
, pkgs
, lib
, ...
}:
{
  services = {
    fail2ban-cloudflare = {
      enable = true;
      apiKeyFile = config.sops.secrets."cloudflare/firewallApiKey".path;
      zoneId = config.sops.secrets."cloudflare/zoneId".path;
    };
    plex = {
      enable = true;
      settings = {
        transcoding = {
          hardwareAcceleration = true;
          vaapi.enable = true;
        };
      };
    };
  };

  hardware.enableAllFirmware = true;
  hardware.pulseaudio.enable = true;
  hardware.video.intel.enable = true;

  networking.firewall.allowedTCPPorts = [ 32400 ]; # Allow Plex port
  networking.firewall.allowedUDPPorts = [ 32400 ]; # Allow Plex port

  users.users.plex = {
    isNormalUser = true;
    home = "/var/lib/plex";
    shell = pkgs.bash;
  };
}
