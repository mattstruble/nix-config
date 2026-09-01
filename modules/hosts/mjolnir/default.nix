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
          8556 # llama.cpp Qwen3.8-Flash-Next primary, MTP (GPU 0)
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

      # Qwen3.8-Flash-Next (125B-class hybrid-SSM MoE) on GPU 0 — coding/agentic.
      # Replaces Qwen3.8-27B (2026-09-01, user go/no-go): 125B-class quality +
      # 256k context outweigh the 2x decode slowdown (20 vs 40 tok/s).
      #
      # Requires the mjungnickel18 llama.cpp FORK — upstream cannot run this
      # model's MTP + MoE expert residency. Branch qwen4exp-mtp-plus-moe-residency
      # @ 0384f5c ("moe: split routed experts by residency across backends"),
      # built for sm_75 in /var/lib/llama-builds/llama-fork-mjungnickel; source in
      # /var/lib/llama-builds/llama-fork-src (rebuild via the fn-build.sh recipe if
      # the branch moves). Runtime image is the CUDA 12.6 base the build links
      # against (digest pinned — the floating-tag-moved lesson from the 3.6/3.8
      # retunes applies to any image that ships inference code; this one only
      # ships the CUDA runtime, but pin anyway).
      #
      # Model: Q3_K_XL (92GB) with MoE experts split hot/cold (timadinorth patch):
      # hot64 traced experts in VRAM, cold on CPU via -ot "exps_cold=CPU". MTP
      # sidecar is the jockeupptaget Q8_0 extraction — its separate
      # fc_embedding/fc_hidden layout is what the fork expects; sidecars with the
      # fused eh_proj layout (the Q4_K_M ones) are incompatible.
      #
      # Bench 2026-09-01 (Titan RTX, this exact config): decode 18.7-20.6 tok/s
      # @4k/15k/51k, 19.5 tok/s @122k depth (flat — hybrid SSM), MTP acceptance
      # 0.87-0.98 (mean draft len 4.1-5.6), 1.75x the non-MTP baseline (11.5),
      # tool calling OK. 78-90% of the 3090 reference (24-26 t/s).
      # FA on is a hard requirement: q8_0 KV needs it, f16 KV OOMs on 24GB.
      # Uses the built-in template (--jinja, validated incl. tool calling). If
      # opencode's multi-system-message "System message must be at the beginning"
      # error shows up, mount the vendored qwen3 template like llama-qwen36 does.
      #
      # -ub 1024 (validated 2026-09-01: full 121,676-token prefill at 142 tok/s,
      # decode 19.5 @122k, VRAM peak 22.5GB). The FA compute workspace scales
      # with ubatch x KV depth: -ub 2048 OOMs at ~120k KV (server segfaults
      # mid-prefill), -ub 256 fits but prefills at only 60 tok/s. ub1024 is the
      # fastest that fits 24GB; a 15k first prompt ≈ 65s (vs ~4 min at ub256).
      # Turns 2+ skip re-prefill via native slot prefix reuse (cached_tokens
      # ≈ 100%), so only session start pays it. To go faster: free ~3.4GB
      # (H=48 split + Q4_K_M sidecar) for -ub 2048 — see beads ticket.
      #
      # 256k mode (no MTP — MTP + 256k KV + FA workspace = 24.05GB > 24GB):
      # drop -md and the spec flags, set -c 262144 (keep -ub 256). Bench:
      # prefill 54 tok/s, decode 11 tok/s at 257k depth, long-context retention
      # correct. Use when a session outgrows 128k; 3.6 on GPU 1 covers
      # long-context speed in the meantime.
      virtualisation.oci-containers.containers.llama-flashnext = {
        image = "nvidia/cuda@sha256:af25d2ef68f7aedaf0eb179e67773e64feefc3b65a12f59a6cd604ca7c53bb57";
        ports = [ "8556:8080" ];
        volumes = [
          "/var/lib/llama-models:/models"
          "/var/lib/llama-builds/llama-fork-mjungnickel:/bb"
        ];
        environment = {
          GGML_CUDA_DISABLE_GRAPHS = "1";
          LD_LIBRARY_PATH = "/bb/lib:/bb/bin";
        };
        cmd = [
          "/bb/bin/llama-server"
          "-m"
          "/models/UD-Q3_K_XL-split96/Qwen3.8-Flash-Next-UD-Q3_K_XL-hot64.gguf"
          "-md"
          "/models/mtp-fn-jockeupptaget-Q8_0.gguf"
          "--spec-type"
          "draft-mtp"
          "--spec-draft-n-max"
          "6"
          "--spec-draft-p-min"
          "0.75"
          "--alias"
          "qwen3.8-flash-next"
          "-ot"
          "exps_cold=CPU"
          "-ngl"
          "99"
          "-c"
          "131072"
          "-np"
          "1"
          "-ub"
          "1024"
          "--cache-type-k"
          "q8_0"
          "--cache-type-v"
          "q8_0"
          "--flash-attn"
          "on"
          "--jinja"
          "--reasoning-budget"
          "8192"
          "--temp"
          "0.6"
          "--top-k"
          "20"
          "--top-p"
          "0.95"
          "--min-p"
          "0"
          "--host"
          "0.0.0.0"
          "--port"
          "8080"
          "--api-key"
          "foo"
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
      # IQ4_XS GGUF (unsloth -MTP repo), 256k context, full offload (-ngl 99),
      # -np 2 (128k per user). Tuned 2026-08-27 after A/B bench: FA off (hybrid
      # SSM fattn path broken in this build — 51k prefill 14.6 vs 951 tok/s),
      # q8_0 K + f16 V KV (3.3x decode vs q5_1, 14/14 planted-name quality), MTP
      # removed (draft path O(n) at length: 5.7 tok/s @16k vs 53 without).
      # Digest pinned — the floating tag changed FA behavior between 08-25 and 08-26.
      # Re-enable MTP once llama.cpp upstream #24670 (draft path missing SSM state)
      # is fixed and lands in a new pinned image build.
      virtualisation.oci-containers.containers.llama-qwen36 = {
        image = "ghcr.io/ggml-org/llama.cpp@sha256:41ebf873c2e085dcc3186dc4717ce8112bf8011aabd98038b6bb2b1fe66c86b9";
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
          "q8_0"
          "--cache-type-v"
          "f16"
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
          "off"
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
