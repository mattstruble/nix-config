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
          vllm
          llama-fleet
        ])
        ++ [
          (inputs.self.lib.modulesPath + "/installer/scan/not-detected.nix")
          ./_hardware-configuration.nix
          ./_llama-models.nix
          ./_locale.nix
        ];

      boot.loader.systemd-boot.enable = true;
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
        # llama.cpp model ports come from the llama-fleet module (derived from
        # the enabled models), so a disabled model closes its port.
      };

      services.tailscale = {
        enable = true;
        useRoutingFeatures = "client";
      };

      # vLLM AWQ-INT4 + MTP dead-ended on Turing (proposer gptq_marlin_repack OOM
      # on one 24GB card). MTP's validated home is llama.cpp+GGUF. nix vLLM module
      # stays off. See docs/cluster-overview.md for the full testing history.
      services.vllm.enable = false;

      # Docker + CDI for per-GPU llama.cpp containers
      virtualisation.docker.enable = true;
      virtualisation.docker.daemon.settings.features.cdi = true;
      hardware.nvidia-container-toolkit.enable = true;
      virtualisation.oci-containers.backend = "docker";

      # ── llama fleet switchboard ──────────────────────────────────────────
      # What runs on which GPU. Model definitions (image, GGUF, flags, host
      # port) live in ./_llama-models.nix — this is the only place you edit to
      # swap models, and retired configs stay there as inert data: flip
      # enable/gpu, never delete. Two enabled models on one GPU fails
      # evaluation. See docs/cluster-overview.md.
      # Keys must match a definition in ./_llama-models.nix exactly — a typo'd
      # key defines a new empty model instead of toggling the one you meant.
      llama.models.qwen3-8-flash-next = {
        enable = true;
        gpu = 0;
      };
      llama.models.qwen3-8-27b = {
        enable = true;
        gpu = 1;
        port = 8555;
      };
      llama.models.qwen3-6-35b-iq4xs = {
        enable = false;
        gpu = 1;
      };
      llama.models.qwen3-8-flash-next-256k = {
        enable = false;
        gpu = 0;
      };

      # Swap patterns: turn off whoever holds the GPU/port first, then
      #   qwen3-8-27b = { enable = true; gpu = 0; }             -> 27B on 8556 (flash-next off)
      #   qwen3-6-35b-iq4xs = { enable = true; gpu = 1; }       -> 3.6 back on 8555 (27B off)
      #   qwen3-8-flash-next-256k = { enable = true; gpu = 0; }  -> 256k, no MTP (flash-next off)

      hardware.nvidia.cudaCapabilities = [ "7.5" ];
      hardware.cpu.amd.updateMicrocode = true;

      environment.systemPackages = with pkgs; [
        pciutils
        nvtopPackages.nvidia
        nvidia-vaapi-driver
      ];
    };
}
