{ ... }:
{
  flake.modules.nixos.k3s =
    { config, lib, pkgs, ... }:
    let
      cfg = config.services.k3s;
      # k8s/ lives at the repo root; this module is in modules/services/.
      k8sDir = ../../k8s;
      # nvidia-container-runtime in CDI mode: reads the host's nvidia CDI spec
      # (which carries the nix-store driver-lib mounts + the nvidia-cdi-hook) and
      # injects the GPU selected by NVIDIA_VISIBLE_DEVICES. The hook-mode runtime
      # is unusable here (it needs nvidia-ctk inside the container, which the nix
      # store doesn't provide). Lives in the toolkit's `tools` output.
      nvidiaRuntime = "${pkgs.nvidia-container-toolkit.tools}/bin/nvidia-container-runtime.cdi";
      # Render the ai chart (helm from nixpkgs) into one manifest file; the
      # post-activation hook below applies it, so `just deploy mjolnir` ships
      # host config + cluster manifests in one generation. ponytail: one chart
      # hardcoded — generalize to a chart list when a second app lands.
      aiChartRendered = pkgs.runCommand "ai-chart-rendered" {
        src = k8sDir;
        nativeBuildInputs = [ pkgs.helm ];
      } ''
        mkdir -p $out
        helm template ai $src/apps/ai \
          -f $src/apps/ai/values.yaml \
          -f $src/apps/ai/values/*.yaml \
          > $out/rendered.yaml
      '';
    in
    {
      config = lib.mkIf cfg.enable {
        services.k3s = {
          role = "server";
          # Lean: no metrics-server (model pods expose their own --metrics later).
          # traefik + coredns kept (LAN-name ingress).
          disable = [ "metrics-server" ];

          # containerd nvidia runtime: pods set runtimeClassName: nvidia +
          # env NVIDIA_VISIBLE_DEVICES=<gpu> to get a SPECIFIC GPU (the runtime
          # injects the nix-store driver libs).
          containerdConfigTemplate = ''
            {{ template "base" . }}

            [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
              runtime_type = "io.containerd.runc.v2"
              [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
                BinaryName = "${nvidiaRuntime}"
          '';

          # k8s manifests auto-applied by k3s: the nvidia RuntimeClass (so pods can
          # set runtimeClassName: nvidia) and local PVs for /nix/store +
          # /var/lib/llama-models (PSS-restricted safe, no raw hostPath in pods).
          manifests = {
            nvidia-runtimeclass = {
              source = "${k8sDir}/manifests/nvidia-runtimeclass.yaml";
            };
            local-pvs = {
              source = "${k8sDir}/manifests/local-pvs.yaml";
            };
          };
        };

        # Apply the rendered ai chart after activation. k3s may still be coming
        # up (fresh install / upgrade), hence the retry loop. Runs as root,
        # `k3s kubectl` picks up /etc/rancher/k3s/k3s.yaml itself.
        system.activationScripts.aiChart = {
          text = ''
            for i in $(seq 1 30); do
              k3s kubectl apply -f ${aiChartRendered}/rendered.yaml && exit 0
              sleep 2
            done
            echo "warning: ai chart apply failed after 60s" >&2
          '';
        };

        networking.firewall.allowedTCPPorts = [ 6443 ];
        # NOTE: the LiteLLM gateway's hostPort 8000 is NOT covered by the
        # firewall above — hostPort traffic is DNAT'd via PREROUTING to the
        # pod CNI interface and never traverses the INPUT chain that
        # networking.firewall controls. The pods themselves are ClusterIP-only
        # and require the
        # --api-key set in the chart.
      };
    };
}
