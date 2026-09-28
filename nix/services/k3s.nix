{ ... }:
{
  flake.modules.nixos.k3s =
    { config, lib, pkgs, ... }:
    let
      cfg = config.services.k3s;
      # k8s/ lives at the repo root; this module is in nix/services/.
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
      # NOTE (h1j.1, 2026-09-24): we deliberately do NOT use
      # services.k3s.autoDeployCharts — it only takes a remote-repo URL or a
      # pre-packaged .tgz with a SINGLE values source, and can't do a local
      # unpacked chart + 9 merged -f values files + .Files.Get. See
      # docs/h1j.1-autodeploycharts.md. Use autoDeployCharts for future
      # remote-repo charts only.
      aiChartRendered = pkgs.runCommand "ai-chart-rendered" {
        src = k8sDir;
        nativeBuildInputs = [ pkgs.kubernetes-helm ];
      } ''
        mkdir -p $out
        # one -f per values file (a bare glob expands to positional chart args)
        F=(-f $src/apps/ai/values.yaml)
        for f in $src/apps/ai/values/*.yaml; do F+=(-f "$f"); done
        helm template ai $src/apps/ai "''${F[@]}" > $out/rendered.yaml
      '';

      # ── Monitoring (Grafana/Prometheus/Loki/Alloy/DCGM) ──────────────
      # All monitoring charts use the render-then-apply pattern (render with
      # `helm template` at build time, `kubectl apply` in the activation script):
      #   - loki/alloy/dcgm: static values → rendered at build time.
      #   - kps: its alertmanager telegram creds + grafana admin password come
      #     from sops, which sops-nix only materialises at RUNTIME (/run/secrets/),
      #     so kps is rendered in the activation script (where the secrets exist).
      # We deliberately do NOT use services.k3s.autoDeployCharts: with
      # `values = <path>` it runs `yq` (fromYaml) at EVALUATION time, which forces
      # a build of an x86_64-linux derivation and breaks cross-arch deploys from
      # the Mac (nix flake check runs on aarch64-darwin). Render-then-apply keeps
      # the render a build-time derivation (built on the target), so eval stays
      # arch-independent. Charts are fetched with fetchurl (allowed in sandboxed
      # builds, unlike a `helm pull` runCommand the sandbox's network block
      # rejects), hash-pinned to the GitHub release .tgz.
      kpsChart = pkgs.fetchurl {
        url = "https://github.com/prometheus-community/helm-charts/releases/download/kube-prometheus-stack-91.7.0/kube-prometheus-stack-91.7.0.tgz";
        sha256 = "989701d6d289a8303b2357e9fcd40522f82932e36ae0d960ed9f9271e167a5bb"; # pragma: allowlist secret
      };
      lokiChart = pkgs.fetchurl {
        url = "https://github.com/grafana-community/helm-charts/releases/download/loki-18.13.5/loki-18.13.5.tgz";
        sha256 = "b26289fadb0eab4335e14fc725df92dfa2cc1d8e94e06a76861cf58a7a1d051a"; # pragma: allowlist secret
      };
      alloyChart = pkgs.fetchurl {
        url = "https://github.com/grafana/helm-charts/releases/download/alloy-1.13.0/alloy-1.13.0.tgz";
        sha256 = "bfdda6cb770c3526444897b9cb5a4fb33711c608d364d9e7857ec699a2fff4fb"; # pragma: allowlist secret
      };

      # DCGM exporter: the chart is BUNDLED in the NVIDIA repo (not a remote
      # helm repo), so fetch the source at the pinned tag and render it — same
      # render-then-apply pattern as the ai chart (see h1j.1 note).
      dcgmChartSrc = pkgs.fetchFromGitHub {
        owner = "NVIDIA";
        repo = "dcgm-exporter";
        rev = "4.8.4";
        # fetchFromGitHub hashes the UNPACKED dir (not the tarball).
        sha256 = "c7239684e46a7547969c45c39532ec02e5843dbdeaf7e8a818939bc32b091419"; # pragma: allowlist secret
      };
      dcgmChartRendered = pkgs.runCommand "dcgm-chart-rendered" {
        nativeBuildInputs = [ pkgs.kubernetes-helm ];
      } ''
        mkdir -p $out
        helm template dcgm-exporter ${dcgmChartSrc}/deployment \
          -f ${k8sDir}/apps/monitoring/values/dcgm-exporter.yaml \
          --namespace monitoring > $out/rendered.yaml
      '';
      # Loki + Alloy: static values, rendered at build time (helm template accepts
      # the pre-fetched .tgz chart directly).
      lokiChartRendered = pkgs.runCommand "loki-chart-rendered" {
        nativeBuildInputs = [ pkgs.kubernetes-helm ];
      } ''
        mkdir -p $out
        helm template loki ${lokiChart} \
          -f ${k8sDir}/apps/monitoring/values/loki.yaml \
          --namespace monitoring > $out/rendered.yaml
      '';
      alloyChartRendered = pkgs.runCommand "alloy-chart-rendered" {
        nativeBuildInputs = [ pkgs.kubernetes-helm ];
      } ''
        mkdir -p $out
        helm template alloy ${alloyChart} \
          -f ${k8sDir}/apps/monitoring/values/alloy.yaml \
          --namespace monitoring > $out/rendered.yaml
      '';
    in
    {
      config = lib.mkIf cfg.enable {
        # Monitoring secrets (mjolnir-decryptable). Consumed by the rendered
        # kps values (telegram) + the grafana admin Secret (grafanaPw) above.
        sops.secrets = {
          "services/monitoring/grafana-admin-password" = {
            sopsFile = ./homelab/homelab-secrets.yaml;
          };
          "services/monitoring/telegram-bot-token" = {
            sopsFile = ./homelab/homelab-secrets.yaml;
          };
          "services/monitoring/telegram-chat-id" = {
            sopsFile = ./homelab/homelab-secrets.yaml;
          };
        };
        # Materialise secrets in the activation script (setupSecrets) instead of
        # a systemd oneshot at boot — the aiChart activation script below reads
        # them and must run after they exist.
        sops.useSystemdActivation = false;

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

        # Expose the rendered charts as toplevel dependencies so they land in
        # the system closure. The activation script below references them only
        # inside strings, which Nix does NOT track as a dependency on its own —
        # without this the paths are never built and the apply fails at deploy
        # time.
        system.build.aiChartRendered = aiChartRendered;
        system.build.dcgmChartRendered = dcgmChartRendered;
        system.build.lokiChartRendered = lokiChartRendered;
        system.build.alloyChartRendered = alloyChartRendered;
        # kps chart (fetched .tgz) — rendered at activation, not build time.
        system.build.kpsChart = kpsChart;

        # Apply the rendered loki/alloy/ai/dcgm charts, and render + apply kps,
        # after activation. k3s may still be coming up (fresh install / upgrade),
        # hence the retry loop. Runs as root, `k3s kubectl` picks up
        # /etc/rancher/k3s/k3s.yaml itself. kps is rendered HERE (not at build
        # time) because its alertmanager telegram creds + grafana admin password
        # come from sops, which only exist in /run/secrets/ at runtime.
        system.activationScripts.aiChart = {
          # k3s + helm + sed aren't on the activation script's default PATH, so
          # use full binary paths. (A store path in `deps` is rejected by deploy-rs.)
          # Run after sops-nix materialises /run/secrets.
          deps = [ "setupSecrets" ];
          text = ''
            KCTL="${pkgs.k3s}/bin/k3s kubectl"
            HELM="${pkgs.kubernetes-helm}/bin/helm"
            KPS_CHART="${kpsChart}"
            KPS_VALUES_SRC="${k8sDir}/apps/monitoring/values/kube-prometheus-stack.yaml"
            SED="${pkgs.gnused}/bin/sed"
            TAR="${pkgs.gnutar}/bin/tar"
            # tar -z spawns gzip as a child; it's not on the activation PATH.
            export PATH="${pkgs.gzip}/bin:$PATH"
            TG_TOKEN="$(cat ${config.sops.secrets."services/monitoring/telegram-bot-token".path})"
            TG_CHAT="$(cat ${config.sops.secrets."services/monitoring/telegram-chat-id".path})"
            GRAFANA_PW="$(cat ${config.sops.secrets."services/monitoring/grafana-admin-password".path})"

            # Fill the sops placeholders in the values, render kps, and build the
            # grafana admin Secret. Done in a temp dir so nothing leaks to the store.
            T=$(mktemp -d)
            trap 'rm -rf "$T"' EXIT
            $SED -e "s|__TELEGRAM_BOT_TOKEN__|$TG_TOKEN|" \
                -e "s|__TELEGRAM_CHAT_ID__|$TG_CHAT|" \
                "$KPS_VALUES_SRC" > "$T/kps-values.yaml"
            # Render the kps templates (CRs + workloads) WITHOUT --include-crds;
            # the CRDs are extracted from the chart and applied separately below.
            $HELM template kps "$KPS_CHART" -f "$T/kps-values.yaml" \
                --namespace monitoring > "$T/kps-rendered.yaml"
            $TAR -xzf "$KPS_CHART" -C "$T"
            # CRDs ship in the chart's `crds` dependency subchart.
            KPS_CRDS="$T/kube-prometheus-stack/charts/crds/crds"

            # CRDs are server-side applied: their openAPIV3Schema overflows the
            # 262144-byte last-applied-configuration annotation, so client-side
            # apply rejects them ("metadata.annotations: Too long"). The CRs are
            # client-side applied: server-side apply's typed patch rejects fields
            # the CRD schema doesn't declare (e.g. Prometheus
            # spec.storage.volumeClaimTemplate.resources), while client-side apply
            # just prunes them. --force-conflicts: we are the sole manager.
            # The operator detects CRDs only at startup; on a fresh install it
            # starts before the CRDs land and disables the prometheus/alertmanager
            # controllers forever, so restart it after the CRDs are in place.
            # kubelet-monitoring SA + RBAC (system:node-reader), then mint its
            # token secret (k8s 1.24+ no longer auto-creates SA token secrets).
            # Long-lived (10y) so it doesn't need re-minting every deploy.
            $KCTL apply -f ${k8sDir}/manifests/kubelet-monitoring.yaml
            $KCTL create token kubelet-monitoring --namespace monitoring \
                --duration=87600h > "$T/kubelet-token"
            $KCTL create secret generic kubelet-monitoring-token \
                --namespace monitoring \
                --from-file=token="$T/kubelet-token" \
                --dry-run=client -o yaml | $KCTL apply -f -

            for i in $(seq 1 30); do
              $KCTL get namespace monitoring >/dev/null 2>&1 || $KCTL create namespace monitoring
              # grafana admin creds as a proper K8s Secret (idempotent apply)
              $KCTL create secret generic monitoring-secrets \
                  --namespace monitoring \
                  --from-literal=admin-user=admin \
                  --from-literal=admin-password="$GRAFANA_PW" \
                  --dry-run=client -o yaml | $KCTL apply -f - \
                && $KCTL apply -f ${lokiChartRendered}/rendered.yaml \
                && $KCTL apply -f ${alloyChartRendered}/rendered.yaml \
                && $KCTL apply -f ${aiChartRendered}/rendered.yaml \
                && $KCTL apply -f ${dcgmChartRendered}/rendered.yaml \
                && $KCTL apply --server-side --force-conflicts -f "$KPS_CRDS" \
                && $KCTL apply -f "$T/kps-rendered.yaml" \
                && $KCTL rollout restart deploy/kps-kube-prometheus-stack-operator --namespace monitoring \
                && { $KCTL delete prometheusrule -n monitoring \
                      kps-kube-prometheus-stack-kubernetes-system-controller-manager \
                      kps-kube-prometheus-stack-kubernetes-system-kube-proxy \
                      kps-kube-prometheus-stack-kubernetes-system-scheduler 2>/dev/null || true; } \
                && exit 0
              sleep 2
            done
            echo "warning: chart apply failed after 60s" >&2
          '';
        };

        # 6443: k3s API server. 9100: node-exporter, 10250: kubelet — both
        # are hostNetwork on the node and scraped by Prometheus from the pod
        # network, so the INPUT chain must let the pod CIDR reach them.
        networking.firewall.allowedTCPPorts = [ 6443 9100 10250 ];
        # NOTE: the LiteLLM gateway's hostPort 8000 is NOT covered by the
        # firewall above — hostPort traffic is DNAT'd via PREROUTING to the
        # pod CNI interface and never traverses the INPUT chain that
        # networking.firewall controls. The pods themselves are ClusterIP-only
        # and require the
        # --api-key set in the chart.
      };
    };
}
