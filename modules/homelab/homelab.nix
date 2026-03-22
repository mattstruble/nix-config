{ inputs, ... }:
let
  nfsServer = "10.0.0.123";
in
{
  flake.modules.nixos.homelab =
    { config, pkgs, lib, ... }:
    {
      sops.secrets = {
        "services/karakeep/env" = {
          sopsFile = ./homelab-secrets.yaml;
        };
        "services/pocket-id/env" = {
          sopsFile = ./homelab-secrets.yaml;
        };
      };

      services = {
        plex = {
          enable = true;
          openFirewall = true;
        };

        pulseaudio.enable = true;

        immich = {
          enable = true;
          host = "127.0.0.1";
          port = 3001;
          accelerationDevices = null;
          openFirewall = false;
          mediaLocation = "/mnt/immich";
        };

        nginx = {
          enable = true;
          recommendedProxySettings = true;
          virtualHosts."immich" = {
            listen = [{ addr = "0.0.0.0"; port = 2283; }];
            locations."/" = {
              proxyPass = "http://127.0.0.1:3001";
              proxyWebsockets = true;
            };
          };
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
          meilisearch.enable = true;
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
          2283 # immich (nginx)
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

      fileSystems."/mnt/media" = {
        device = "${nfsServer}:/volume2/media";
        fsType = "nfs";
        options = [ "nfsvers=4.2" "noexec" "nosuid" "nodev" ];
      };

      fileSystems."/mnt/immich" = {
        device = "${nfsServer}:/volume1/immich";
        fsType = "nfs";
        options = [ "nfsvers=4.2" "noexec" "nosuid" "nodev" ];
      };

      fileSystems."/mnt/pocket-id" = {
        device = "${nfsServer}:/volume1/pocket-id";
        fsType = "nfs";
        options = [ "nfsvers=4.2" "noexec" "nosuid" "nodev" ];
      };
    };
}
