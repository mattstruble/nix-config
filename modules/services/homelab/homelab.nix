{ inputs, ... }:
let
  nfsServer = "10.0.0.123";
in
{
  flake.modules.nixos.homelab =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      sops.secrets = {
        "services/karakeep/env" = {
          sopsFile = ./homelab-secrets.yaml;
        };
        "services/pocket-id/env" = {
          sopsFile = ./homelab-secrets.yaml;
        };
      };

      nixpkgs.config.permittedInsecurePackages = [ "pnpm-9.15.9" ]; # ponytail: build-time only, remove when nixpkgs bumps karakeep off pnpm_9

      services = {
        plex = {
          enable = true;
          openFirewall = true;
        };

        n8n = {
          enable = true;
          openFirewall = true; # 5678
          environment = {
            N8N_SECURE_COOKIE = false;
          };
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
            listen = [
              {
                addr = "0.0.0.0";
                port = 2283;
              }
            ];
            locations."/" = {
              proxyPass = "http://127.0.0.1:3001";
              proxyWebsockets = true;
            };
          };
        };

        seerr = {
          enable = true;
          openFirewall = true;
        };

        tailscale = {
          enable = true;
          useRoutingFeatures = "server";
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
          meilisearch.enable = false;
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

      # Force tailscaled to use nftables (Critical for clean nftables-only systems)
      # This avoids the "iptables-compat" translation layer issues.
      systemd.services.tailscaled.serviceConfig.Environment = [
        "TS_DEBUG_FIREWALL_MODE=nftables" # pragma: allowlist secret
      ];

      # Optimization: Prevent systemd from waiting for network online
      # (Optional but recommended for faster boot with VPNs)
      systemd.network.wait-online.enable = false;
      boot.initrd.systemd.network.wait-online.enable = false;

      networking.nftables.enable = true;
      networking.firewall = {
        enable = true;
        trustedInterfaces = [ config.services.tailscale.interfaceName ];
        allowedUDPPorts = [ config.services.tailscale.port ];
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
      };

      fileSystems."/mnt/immich" = {
        device = "${nfsServer}:/volume1/immich";
        fsType = "nfs";
      };

      fileSystems."/mnt/pocket-id" = {
        device = "${nfsServer}:/volume1/pocket-id";
        fsType = "nfs";
      };
    };
}
