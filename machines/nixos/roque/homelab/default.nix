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

    pocket-id = {
      enable = true;
      dataDir = "/mnt/pocket-id";
      environmentFile = config.sops.secrets."services/pocket-id/env".path;
      settings = {
        APP_URL = "https://auth.struble.app";
        TRUST_PROXY = true;
      };
    };

    karakeep = {
      enable = true;
      browser = {
        enable = true;
        exe = "${pkgs.ungoogled-chromium}/bin/chromium";
      };
      meilisearch.enable = true; # FIXME: broken
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
  };

  networking.firewall = {
    allowedTCPPorts = [
      3000 # karakeep
      1411 # pocket-id
    ];
  };

  users.groups = {
    immich.gid = lib.mkForce 65541;
    pocket-id.gid = lib.mkForce 65542;
  };

  users.users = {
    pocket-id = {
      uid = lib.mkForce 1040;
    };
    immich = {
      uid = lib.mkForce 1039;

      extraGroups = [
        "video"
        "render"
      ];
    };
  };

}
