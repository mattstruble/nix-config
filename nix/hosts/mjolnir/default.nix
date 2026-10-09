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
      # Server + nvidia runtime + local PVs: nix/services/k3s.nix (keyed
      # off this flag). Model pods + LiteLLM gateway: k8s/apps/ai chart
      # (`just k8s-deploy`). Fork binaries are nix-built (_llama-fork.nix,
      # _llama-turboq.nix) and mounted into the pods.
      services.k3s.enable = true;

      # Required by the k3s nvidia runtime (k3s.nix), which is CDI-mode: it
      # reads the host's CDI spec (/var/run/cdi/nvidia-container-toolkit.json),
      # which only the toolkit's cdi-generator service produces. Dropping this
      # breaks every GPU pod. Host-specific, so it lives here, not in the
      # host-agnostic k3s module.
      hardware.nvidia-container-toolkit.enable = true;

      hardware.nvidia.cudaCapabilities = [ "7.5" ];
      hardware.cpu.amd.updateMicrocode = true;

      # Strata engine bundle (engine + server + python env) for the Qwen3.8-Flash-Next
      # pod. Built natively (sm_75) and mounted into the pod via the nix-store PVC
      # (the nixBinary pattern, like the llama.cpp fork). The model/pack/MTP live on
      # the models PVC, not here. callPackage auto-provides cudaPackages/python3/deps.
      system.build.strata = pkgs.callPackage ./_strata.nix { };
      # The values file pins a literal store path, and the pod mounts /nix/store
      # (a local PV on the real store) - but system.build.strata only enters the
      # GC graph through whatever root points at it. Verified on mjolnir: neither
      # the current nor the previous system profile references the bundle
      # (`nix-store -q --references /nix/var/nix/profiles/system-169-link | grep
      # strata` is empty), so a generation is NOT a reference - the only roots
      # were the manual one below and a transient /nix/var/nix/gcroots/auto entry
      # from the build itself. Without a root the pod CrashLoops on a vanished
      # bundle at its next restart.
      #
      # The root is maintained by a service rather than a tmpfiles rule so that
      # the outgoing target can be snapshotted first: a tmpfiles rule rewrites
      # strata-bundle in place, which makes the bundle the running pod is still
      # executing collectable the moment the new one lands (and a rollback would
      # have nothing to build from). One unit, no ordering race with
      # systemd-tmpfiles-setup: read the old target, park it on -prev, then point
      # the root at the new path. Exactly one prior bundle is kept - enough to
      # roll back to, and it does not accumulate.
      systemd.services."strata-bundle-roots" = {
        wantedBy = [ "multi-user.target" ];
        before = [ "k3s.service" ];
        serviceConfig = {
          type = "oneshot";
          remainAfterExit = true;
        };
        # the script embeds the new path, so its unit definition changes on every
        # bundle change - which is what makes the activation restart it.
        script = ''
          cur=/nix/var/nix/gcroots/manual/strata-bundle
          prev=/nix/var/nix/gcroots/manual/strata-bundle-prev
          new=${config.system.build.strata}
          if [ -L "$cur" ]; then
            old=${pkgs.coreutils}/bin/readlink "$cur"
            if [ "$old" != "$new" ]; then ${pkgs.coreutils}/bin/ln -sfn "$old" "$prev"; fi
          fi
          ${pkgs.coreutils}/bin/ln -sfn "$new" "$cur"
        '';
      };

      environment.systemPackages = with pkgs; [
        pciutils
        nvtopPackages.nvidia
        nvidia-vaapi-driver
      ];
    };
}
