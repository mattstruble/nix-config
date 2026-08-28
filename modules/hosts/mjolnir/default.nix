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
        ])
        ++ [
          (inputs.self.lib.modulesPath + "/installer/scan/not-detected.nix")
          ./_hardware-configuration.nix
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
        allowedTCPPorts = [
          8555 # llama.cpp Qwen3.6-35B-A3B fallback (GPU 1)
          8556 # llama.cpp Qwen3.8-27B primary, MTP (GPU 0)
        ];
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

      # Qwen3.8-27B on GPU 0 — coding/agentic (accuracy-primary).
      # Q4_K_XL GGUF, 128k context, q8_0 KV, MTP n-max 2, flash-attn on.
      # Single-user (-np 1) — full context for one coder.
      # Bench 2026-08-27 (pinned build): prefill 626/575/485 tok/s @15k/30k/60k
      # (~2x the floating tag in prod), decode 43.7/43.6/35.0, MTP 1.68-1.79x with
      # no O(n) collapse at length (unlike 3.6), quality 14/14, tool calling OK.
      # FA on is a hard requirement: quantized V cache requires it, and f16 V at
      # 128k OOMs. 256k infeasible on 24GB (q8_0 OOM, q5_1 V FA path broken:
      # 28 tok/s prefill). Digest pinned — same build validated for 3.6; the
      # floating tag had moved and degraded prefill. Cold-start first request
      # after load is 96.4s @15k (warm ~24s) — deterministic.
      virtualisation.oci-containers.containers.llama-qwen38 = {
        image = "ghcr.io/ggml-org/llama.cpp@sha256:41ebf873c2e085dcc3186dc4717ce8112bf8011aabd98038b6bb2b1fe66c86b9";
        ports = [ "8556:8556" ];
        volumes = [
          "/var/lib/llama-models:/models"
          "${./qwen3-chat-template.jinja}:/app/qwen3-chat-template.jinja:ro"
        ];
        environment = {
          GGML_CUDA_DISABLE_GRAPHS = "1";
        };
        cmd = [
          "-m"
          "/models/Qwen3.8-27B-UD-Q4_K_XL.gguf"
          "--alias"
          "qwen3.8-27b"
          "-ngl"
          "99"
          "-c"
          "131072"
          "--cache-type-k"
          "q8_0"
          "--cache-type-v"
          "q8_0"
          "--host"
          "0.0.0.0"
          "--port"
          "8556"
          "--api-key"
          "foo"
          "--jinja"
          "--chat-template-file"
          "/app/qwen3-chat-template.jinja"
          "--chat-template-kwargs"
          ''{"reasoning_effort":"medium","preserve_thinking":true}''
          "--reasoning-budget"
          "8192"
          "--spec-type"
          "draft-mtp"
          "--spec-draft-n-max"
          "2"
          "--spec-draft-n-min"
          "1"
          "--temp"
          "0.6"
          "--top-k"
          "20"
          "--top-p"
          "0.95"
          "--min-p"
          "0"
          "-ub"
          "256"
          "-np"
          "1"
          "--flash-attn"
          "on"
        ];
        extraOptions = [
          "--device"
          "nvidia.com/gpu=0"
          "--shm-size"
          "32g"
          "--ipc=host"
        ];
      };

      # Qwen3.6-35B-A3B MoE on GPU 1 — dispatch/chat/HA/n8n (speed-primary).
      # IQ4_XS-MTP GGUF (from unsloth -MTP repo — has MTP head), 256k context,
      # full offload (-ngl 99, was -ngl 40 = 74→121 tok/s), -np 2 for 2 concurrent
      # users, flash-attn for long-prompt prefill speed, q5_1 KV (minimum viable).
      virtualisation.oci-containers.containers.llama-qwen36 = {
        image = "ghcr.io/ggml-org/llama.cpp:server-cuda";
        ports = [ "8555:8555" ];
        volumes = [
          "/var/lib/llama-models:/models"
          "${./qwen3-chat-template.jinja}:/app/qwen3-chat-template.jinja:ro"
        ];
        environment = {
          GGML_CUDA_DISABLE_GRAPHS = "1";
        };
        cmd = [
          "-m"
          "/models/Qwen3.6-35B-A3B-MTP-UD-IQ4_XS.gguf"
          "--alias"
          "Qwen3.6-35B-A3B"
          "-ngl"
          "99"
          "-c"
          "262144"
          "--cache-type-k"
          "q5_1"
          "--cache-type-v"
          "q5_1"
          "--host"
          "0.0.0.0"
          "--port"
          "8555"
          "--api-key"
          "foo"
          "--jinja"
          "--chat-template-file"
          "/app/qwen3-chat-template.jinja"
          "--chat-template-kwargs"
          ''{"reasoning_effort":"medium","preserve_thinking":true}''
          "--reasoning-budget"
          "8192"
          "--spec-type"
          "draft-mtp"
          "--spec-draft-n-max"
          "2"
          "--spec-draft-n-min"
          "1"
          "--temp"
          "0.6"
          "--top-k"
          "20"
          "--top-p"
          "0.95"
          "--min-p"
          "0"
          "-ub"
          "256"
          "-np"
          "2"
          "--flash-attn"
          "on"
        ];
        extraOptions = [
          "--device"
          "nvidia.com/gpu=1"
          "--shm-size"
          "32g"
          "--ipc=host"
        ];
      };

      hardware.nvidia.cudaCapabilities = [ "7.5" ];
      hardware.cpu.amd.updateMicrocode = true;

      environment.systemPackages = with pkgs; [
        pciutils
        nvtopPackages.nvidia
        nvidia-vaapi-driver
      ];
    };
}
