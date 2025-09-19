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
      openFirewall = true;
      browser = {
        enable = true;
        package = pkgs.ungoogled-chromium;
      };
      meilisearch.enable = true;
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

  users.groups.immich.gid = lib.mkForce 65541;

  users.users.immich = {
    uid = lib.mkForce 1039;

    extraGroups = [
      "video"
      "render"
    ];
  };

}
