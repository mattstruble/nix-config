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
          k3s
        ])
        ++ [
          (inputs.self.lib.modulesPath + "/installer/scan/not-detected.nix")
          ./_hardware-configuration.nix
          ./_llama-models.nix
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

      # ── k3s (Phase 1: LLM fleet as k8s pods) ──────────────────────────
      # The server + nvidia runtime + CDI plugin + local PVs all live in
      # modules/services/k3s.nix (keyed off this enable flag). See
      # ~/llm-wiki/plans/k3s-mjolnir-migration.md.
      services.k3s.enable = true;

      # ── llama fleet switchboard ──────────────────────────────────────────
      # What runs on which GPU. Model definitions (image, GGUF, flags, host
      # port) live in ./_llama-models.nix — this is the only place you edit to
      # swap models, and retired configs stay there as inert data: flip
      # enable/gpu, never delete. Two enabled models on one GPU fails
      # evaluation. See docs/cluster-overview.md.
      # Keys must match a definition in ./_llama-models.nix exactly — a typo'd
      # key defines a new empty model instead of toggling the one you meant.
      llama.models.qwen3-8-flash-next = {
        enable = false;
        gpu = 0;
      };
      llama.models.qwen3-8-27b = {
        enable = false;
        gpu = 0;
      };
      # Incumbent voice + classification endpoint, RETIRED from GPU 1 on 2026-09-14 in
      # favour of gemma-4-26b-a4b (tools/gpu1-model-selection/FINDINGS.md). Kept enabled-
      # capable, not deleted: rollback is enable = true here, enable = false on gemma, and
      # `just deploy`. Its vendored chat template and 262k context are still in
      # ./_llama-models.nix.
      llama.models.qwen3-6-35b-iq4xs = {
        enable = false;
        gpu = 1;
        port = 8555;
      };
      # DORMANT (2026-09-11): TBQ4 KV variant — rejected on sm_75 (slower than
      # q8_0 at every depth). The winning turboq+SWA+q8_0 config is qwen3-8-27b.
      llama.models.qwen3-8-27b-turboq = {
        enable = false;
        gpu = 1;
      };
      llama.models.qwen3-8-flash-next-256k = {
        enable = false;
        gpu = 0;
      };
      # ENABLED on GPU 1 since 2026-09-14: voice + n8n classification, reasoning OFF
      # (tools/gpu1-model-selection/FINDINGS.md). Inherits port 8555, so HA Voice Assist
      # and the n8n flows need no changes. Wins on speakable latency (0.06s vs the
      # incumbent's 8.5s of thinking before any audio), prefill, 100k recall and enum
      # compliance. Known regression to watch: single-turn tool choice 0.60 vs 0.90 — the
      # model prefers the no-arg list_areas tool for action requests, and the HA service
      # catalogue in the prompt does not fix it (0.60 at temp 0.2 and 0.7).
      # Rollback: qwen3-6-35b-iq4xs.enable = true, this enable = false, just deploy.
      # See decisions/2026-09-14-thinking-is-an-endpoint-property: thinking cannot be
      # requested per call, so an agentic flow that wants deliberation needs its own GPU.
      llama.models.gemma-4-26b-a4b = {
        enable = false;
        gpu = 1;
      };
      llama.models.gemma-4-26b-a4b-longctx = {
        enable = false;
        gpu = 1;
      };

      # MEASURED, NOT ADOPTED (2026-09-15, nix-config-ah6): Swift-Qwen3.8-27B is parity with the
      # incumbent 27B, not the vendor's x1.95 — same G1/G2/G3, decode parity, -27% thinking tokens
      # (not -58%) which pays out only on 2-7s probes and costs 5% at 80k. Cost of adopting is real:
      # gated Swift Open v1.0 license (not flake-reproducible) and the Q4_K_M tier that fits 24GB is
      # the one that costs the tool-choice probe. Args, numbers and the arm-B sampler trap live in
      # ./_llama-models.nix:swift-qwen3-8-27b and tools/gpu1-model-selection/SWIFT-AB.md.
      llama.models.swift-qwen3-8-27b = {
        enable = false;
        gpu = 0;
      };

      # Swap patterns: turn off whoever holds the GPU/port first, then
      #   qwen3-8-flash-next = { enable = true; gpu = 0; }      -> flash-next back on 8556 (27B off)
      #   qwen3-6-35b-iq4xs = { enable = true; gpu = 1; }       -> 3.6 on 8555 (27B off)
      #   qwen3-8-flash-next-256k = { enable = true; gpu = 0; }  -> 256k, no MTP (27B off)
      #   gemma-4-26b-a4b = { enable = true; gpu = 1; }          -> Gemma 4 on 8555 (3.6 off)
      #   gemma-4-26b-a4b-longctx = { enable = true; gpu = 1; }  -> Gemma 4 at 256k on 8557,
      #                                                            no MTP, no co-enable
      #   swift-qwen3-8-27b = { enable = true; gpu = 1; }         -> Swift 27B on 8558 (gemma off GPU1;
      #                                                            HA voice + n8n lose their endpoint)

      hardware.nvidia.cudaCapabilities = [ "7.5" ];
      hardware.cpu.amd.updateMicrocode = true;

      environment.systemPackages = with pkgs; [
        pciutils
        nvtopPackages.nvidia
        nvidia-vaapi-driver
      ];
    };
}
