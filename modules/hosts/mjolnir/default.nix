{ inputs, ... }:
{
  flake.nixosConfigurations = inputs.self.lib.mkNixos "x86_64-linux" "mjolnir";

  # Files prefixed with _ are excluded from import-tree auto-discovery
  flake.modules.nixos.mjolnir =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    {
      imports =
        (with inputs.self.modules.nixos; [
          tier-server
          nvidia-hardware
          k3s
        ])
        ++ [
          (inputs.self.lib.modulesPath + "/installer/scan/not-detected.nix")
          ./_hardware-configuration.nix
          ./_locale.nix
        ];

      boot.loader.systemd-boot.enable = true;
      # ponytail: /boot is a 1GB partition; unlimited boot entries (one per
      # generation, each ~180MB initrd) filled it and broke deploys on
      # 2026-09-18. Cap at 3 generations so old kernels/initrds are pruned.
      boot.loader.systemd-boot.configurationLimit = 3;
      boot.loader.efi.canTouchEfiVariables = true;

      networking.hostName = "mjolnir";
      system.stateVersion = "26.11";

      # ponytail: 64 cores exhausts 96GB RAM during CUDA/Cython C++ compilation
      nix.settings.cores = 8;

      # ponytail: 32G swapfile absorbs CUDA compilation memory spikes (nvcc cicc)
      swapDevices = [
        {
          device = "/swapfile";
        }
      ];

      # TODO: switch to static bond0 10.0.0.168 once deploy-rs is working
      # Integrated NICs are bonded via LACP (802.3ad) on the switch
      # networking.networkmanager.enable = lib.mkForce false;
      # networking.bonds.bond0 = {
      #   interfaces = [
      #     "eno1"
      #     "enp69s0"
      #   ];
      #   driverOptions = {
      #     mode = "802.3ad";
      #     xmit_hash_policy = "layer2";
      #     lacp_rate = "fast";
      #     miimon = "100";
      #     ad_select = "stable";
      #   };
      # };
      # networking.interfaces.bond0 = {
      #   ipv4.addresses = [
      #     {
      #       address = "10.0.0.168";
      #       prefixLength = 24;
      #     }
      #   ];
      #   ipv4.routes = [
      #     {
      #       address = "0.0.0.0";
      #       prefixLength = 0;
      #       via = "10.0.0.1";
      #     }
      #   ];
      # };
      # networking.defaultGateway = "10.0.0.1";
      # networking.nameservers = [ "10.0.0.1" ];

      # Force tailscaled to use nftables (clean nftables-only systems)
      systemd.services.tailscaled.serviceConfig.Environment = [
        "TS_DEBUG_FIREWALL_MODE=nftables" # pragma: allowlist secret
      ];

      systemd.network.wait-online.enable = false;
      boot.initrd.systemd.network.wait-online.enable = false;

      networking.nftables.enable = true;
      networking.firewall = {
        enable = true;
        trustedInterfaces = [ config.services.tailscale.interfaceName ];
        allowedUDPPorts = [ config.services.tailscale.port ];
      };

      services.tailscale = {
        enable = true;
        useRoutingFeatures = "client";
      };

      # ── k3s (LLM fleet as k8s pods) ────────────────────────────────────
      # The server + nvidia runtime + CDI plugin + local PVs all live in
      # modules/services/k3s.nix (keyed off this enable flag). Model pods +
      # the LiteLLM gateway are the helm chart in k8s/llama-fleet (deploy:
      # `just k8s-deploy`). The old docker switchboard (llama.models.*) was
      # retired 2026-09-19; fork binaries are still nix-built
      # (_llama-fork.nix, _llama-turboq.nix) and mounted into the pods.
      services.k3s.enable = true;

      # The k3s nvidia runtime (k3s.nix) is CDI-mode: it reads the host's CDI
      # spec (/var/run/cdi/nvidia-container-toolkit.json), which only the
      # toolkit's cdi-generator service produces. b595279 removed this line
      # with the docker block, which would drop the generator on the next
      # deploy and break every GPU pod. Host-specific, so it lives here, not
      # in the host-agnostic k3s module.
      hardware.nvidia-container-toolkit.enable = true;

      hardware.nvidia.cudaCapabilities = [ "7.5" ];
      hardware.cpu.amd.updateMicrocode = true;

      environment.systemPackages = with pkgs; [
        pciutils
        nvtopPackages.nvidia
        nvidia-vaapi-driver
      ];
    };
}
