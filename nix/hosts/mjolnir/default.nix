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
      # off this flag). Model pods + LiteLLM gateway: k8s/apps/ai chart,
      # rendered at build and applied by the ai-chart-apply oneshot on
      # `just deploy mjolnir`.
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
      # (the nixBinary pattern - now the only pod that uses it). The model/pack/MTP live on
      # the models PVC, not here. callPackage auto-provides cudaPackages/python3/deps.
      system.build.strata = pkgs.callPackage ./_strata.nix { };
      # The bundle reaches the pod through the build, not through a value typed
      # into a values file: services.k3s.aiChart.strataBundle feeds the chart
      # render (nix/services/k3s.nix) so the pod mounts the path the build
      # produced, and the bundle is retained because system.build.strata is in
      # the toplevel closure - so the generation that produced it retains it, and
      # so does the previous generation, which is what a rollback needs.
      #
      # This replaced three workarounds for the transcription that used to sit
      # here: a literal /nix/store path in the values file, a CI job to notice
      # when it drifted from what the config built, and a manual GC root (plus a
      # -prev root for rollbacks) to stop the path being collected out from under
      # a running pod. None of them were needed once the bundle was in the
      # toplevel closure; a generation is not a reference to paths merely
      # mentioned in its scripts, which is why the literal needed all that
      # scaffolding and this does not.
      # Measured 2026-11-12 from inside the bookstack pod: auth.struble.app resolves
      # to this through public DNS, and the pod's OIDC discovery request goes there,
      # not to roque. The LAN segment is deliberately absent - it contains the node,
      # where traefik answers for every SNI route in the cluster (measured the same
      # day: https://10.0.0.4 with SNI grafana.mjolnir returned 302).
      services.k3s.wikiOidcEgressCidrs = [ "66.63.168.18/32" ];

      services.k3s.aiChart.strataBundle = toString config.system.build.strata;

      # Swap head-end bundle: llama-swap at a pinned commit plus this repo's
      # swapk8s shim. Pure Go, so unlike strata it needs no CUDA toolchain - but
      # it is still an x86_64-linux derivation, so it builds natively here.
      # Wired into the render the same way, for the same reason: the store path is
      # a build input of the manifest, not a string in a values file.
      system.build.swapHeadEnd = pkgs.callPackage ./_swapk8s.nix { };
      services.k3s.aiChart.headEndBundle = toString config.system.build.swapHeadEnd;

      # Both bundles travel to the pod as a store path embedded in the k8s
      # manifest with its string context discarded (nix/services/k3s.nix does the
      # discarding, because a context-carrying string in the values text makes the
      # flake's eval realise a dynamic derivation it refuses to). A path that is
      # only mentioned is not a dependency of anything, so deploy-rs — which
      # builds and copies the toplevel closure — never learns of it, and the first
      # deploy after either bundle's source changes points a pod at a store path
      # that exists on no machine. That is not a hypothetical: the 2026-11-27
      # swapk8s eviction change produced a new derivation hash, the deploy shipped
      # a manifest naming a path that was on neither the build machine nor the
      # host, and the head-end pod crash-looped on `llama-swap: not found` until
      # the bundle was built on the host by hand. extraDependencies is what makes
      # the lie of the discarded context harmless: the toplevel now cannot be
      # built without building both bundles, so a deploy that succeeds has also
      # shipped them.
      system.extraDependencies = [
        config.system.build.strata
        config.system.build.swapHeadEnd
        # The CUDA diffusion CLI the nightly renders with. Named here because
        # the nixpkgs build is the only one that both evaluates on this host and
        # actually renders on a card; left empty the render would resolve
        # `sd-cli` from a container PATH that has no such thing.
        pkgs.stable-diffusion-cpp
      ];

      services.k3s.forecats.sdCliBinary = toString pkgs.stable-diffusion-cpp;

      # kubectl is on the host PATH because the forecats claimer mounts it from
      # the store volume the same way it mounts the bundles above: a store path
      # embedded in the manifest. Being in systemPackages is what puts it in the
      # toplevel closure, so a deploy that succeeds has also copied the exact
      # kubectl the manifest names — same reason as the extraDependencies above,
      # and the same failure if it were left out.
      environment.systemPackages = with pkgs; [
        kubectl
        pciutils
        nvtopPackages.nvidia
        nvidia-vaapi-driver
      ];
    };
}
