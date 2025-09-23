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

    immich = {
      enable = true;
      host = "0.0.0.0";
      accelerationDevices = null; # 'null' give access to all devices
      openFirewall = true;
      mediaLocation = "/mnt/immich";
    };

    overseerr = {
      enable = true;
      openFirewall = true;
    };

    karakeep = {
      enable = true;
      browser = {
        enable = true;
        exe = "${pkgs.ungoogled-chromium}/bin/chromium";
      };
      meilisearch.enable = false; # FIXME: broken
      environmentFile = config.sops.secrets."services/karakeep/env".path;
      extraEnvironment = {
        BROWSER_ARGS = lib.concatStringsSep " " [
          "--headless"
          "--no-sandbox"
          "--disable-gpu"
          "--disable-dev-shm-usage"
          "--disable-extensions"
          "--disable-plugins"
          "--disable-images"
          "--disable-javascript"
          "--virtual-time-budget=5000"
          "--disable-background-timer-throttling"
          "--disable-backgrounding-occluded-windows"
          "--disable-renderer-backgrounding"
        ];
      };
    };

    hedgedoc = {
      enable = true;
      environmentFile = config.sops.secrets."services/hedgedoc/env".path;
      settings = {
        host = "0.0.0.0";
        port = 3030;
        protocolUseSSL = true;
      };
    };
  };

  networking.firewall = {
    allowedTCPPorts = [
      3000 # karakeep
      3030 # hedgedoc
    ];
  };

  users.groups.immich.gid = lib.mkForce 65541;

  users.users.immich = {
    uid = lib.mkForce 1039;

    extraGroups = [
      "video"
      "render"
    ];
  };

}
