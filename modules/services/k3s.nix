{ ... }:
{
  flake.modules.nixos.k3s =
    { config, lib, pkgs, ... }:
    let
      cfg = config.services.k3s;
      # k8s/ lives at the repo root; this module is in modules/services/.
      k8sDir = ../../k8s;
      # The nvidia-container-runtime in CDI mode: reads the host's nvidia CDI spec
      # (which carries the nix-store driver-lib mounts + the nvidia-cdi-hook) and
      # injects the GPU selected by NVIDIA_VISIBLE_DEVICES — the containerd
      # equivalent of docker's --gpus. The hook-mode runtime is unusable here (it
      # needs nvidia-ctk inside the container, which the nix store doesn't provide).
      # Lives in the toolkit's `tools` output.
      nvidiaRuntime = "${pkgs.nvidia-container-toolkit.tools}/bin/nvidia-container-runtime.cdi";
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
          # injects the nix-store driver libs, exactly like docker --gpus does).
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
              source = "${k8sDir}/nvidia-runtimeclass.yaml";
            };
            local-pvs = {
              source = "${k8sDir}/local-pvs.yaml";
            };
          };
        };

        networking.firewall.allowedTCPPorts = [ 6443 ];
        # NOTE: the LiteLLM gateway's hostPort 8000 is NOT covered by the
        # firewall above — hostPort traffic is DNAT'd via PREROUTING to the
        # pod CNI interface and never traverses the INPUT chain that
        # networking.firewall controls. Exposure is LAN+tailscale, same as the
        # docker era. The pods themselves are ClusterIP-only and require the
        # --api-key set in the chart.
      };
    };
}
