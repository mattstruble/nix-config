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
      # dcgm/loki/alloy: static values, rendered at build time (helm template
      # accepts the pre-fetched .tgz chart directly).
      # release: the helm release name (charts embed it in resource names,
      # so it must stay what the cluster already runs).
      monitoringCharts = {
        dcgm = { release = "dcgm-exporter"; chart = "${dcgmChartSrc}/deployment"; values = "${k8sDir}/apps/monitoring/values/dcgm-exporter.yaml"; };
        loki = { release = "loki"; chart = lokiChart; values = "${k8sDir}/apps/monitoring/values/loki.yaml"; };
        alloy = { release = "alloy"; chart = alloyChart; values = "${k8sDir}/apps/monitoring/values/alloy.yaml"; };
      };
      monitoringChartRendered = lib.mapAttrs (name: { release, chart, values }:
        pkgs.runCommand "${name}-chart-rendered" {
          nativeBuildInputs = [ pkgs.kubernetes-helm ];
        } ''
          mkdir -p $out
          helm template ${release} ${chart} \
            -f ${values} \
            --namespace monitoring > $out/rendered.yaml
        ''
      ) monitoringCharts;
    in
    {
      config = lib.mkIf cfg.enable {
        # Host dir for the Postgres static PV (LiteLLM key store). Pre-owned by
        # uid 999 (the postgres image user) so the non-root pod can write it —
        # the cluster's non-root policy forbids a root chown initContainer, and
        # local-path PVs are root-owned. See k8s/manifests/local-pvs.yaml.
        systemd.tmpfiles.rules = [
          "d /var/lib/postgres-data 0700 999 999 -"
        ];

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
          # LiteLLM gateway: master key gates /key/* (just mint-key); the
          # postgres password backs the key store. Both feed the litellm-keys
          # Secret (default ns) the gateway + postgres pods read.
          "services/ai/litellm/master-key" = {
            sopsFile = ./homelab/homelab-secrets.yaml;
          };
          "services/ai/litellm/postgres-password" = {
            sopsFile = ./homelab/homelab-secrets.yaml;
          };
          # Pod API key: authenticates llama-server (LLAMA_API_KEY) + the
          # gateway's OPENAI_API_KEY. Lives in homelab-secrets-ai.yaml (not
          # homelab-secrets.yaml) so it can be re-encrypted from this machine.
          "services/ai/litellm/pod-api-key" = {
            sopsFile = ./homelab/homelab-secrets-ai.yaml;
          };
          # Metrics key: authenticates the Prometheus scrape of the gateway's
          # /metrics (require_auth_for_metrics_endpoint: true). Minted with
          # key_alias "metrics"; same file so it can be re-encrypted from this
          # machine.
          "services/ai/litellm/metrics-key" = {
            sopsFile = ./homelab/homelab-secrets-ai.yaml;
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

          # Stable label for the local PVs' nodeAffinity
          # (k8s/manifests/local-pvs.yaml): selecting on kubernetes.io/hostname
          # would orphan all PVs on a node rename.
          nodeLabel = [ "storage=mjolnir" ];

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
        system.build = {
          aiChartRendered = aiChartRendered;
          # kps chart (fetched .tgz) — rendered at activation, not build time.
          kpsChart = kpsChart;
        } // lib.mapAttrs' (name: chart: lib.nameValuePair "${name}ChartRendered" chart) monitoringChartRendered;

        # Apply the rendered loki/alloy/ai/dcgm charts, and render + apply kps,
        # as a systemd oneshot AFTER k3s is up. Runs as root, `k3s kubectl` picks
        # up /etc/rancher/k3s/k3s.yaml itself. kps is rendered HERE (not at build
        # time) because its alertmanager telegram creds + grafana admin password
        # come from sops, which only exist in /run/secrets/ at runtime.
        #
        # WHY a oneshot and not an activation script: NixOS runs activation
        # scripts BEFORE it restarts/starts units (switch order: stop units →
        # activate → … → restart/start units). So an activation script applies
        # the charts while k3s is still down on any deploy that restarts k3s —
        # the 60s retry loop was futile, and the `exit 1` aborted the whole
        # activation, leaving k3s stopped (the 2026-10-05 deploy failure). A
        # oneshot with After=k3s.service runs once k3s is up, so the apply
        # succeeds in the same deploy and a failure can't take the base system
        # (k3s) down. NixOS re-triggers the oneshot on every deploy that
        # changes the rendered charts (the script embeds them), so charts are
        # applied exactly when they change. The retry loop below covers k3s
        # taking a few seconds to become ready after (re)start.
        systemd.services.ai-chart-apply = {
          description = "Apply k8s charts to k3s after k3s is ready";
          after = [ "k3s.service" ];
          requires = [ "k3s.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExec = true;
          };
          # k3s + helm + envsubst aren't on the oneshot's default PATH, so use
          # full binary paths. Runs after sops-nix materialises /run/secrets
          # (setupSecrets, in the activation phase) and after k3s is up.
          script = ''
            KCTL="${pkgs.k3s}/bin/k3s kubectl"
            HELM="${pkgs.kubernetes-helm}/bin/helm"
            KPS_CHART="${kpsChart}"
            KPS_VALUES_SRC="${k8sDir}/apps/monitoring/values/kube-prometheus-stack.yaml"
            ENVSUBST="${pkgs.envsubst}/bin/envsubst"
            TAR="${pkgs.gnutar}/bin/tar"
            YQ="${pkgs.yq}/bin/yq"
            OPENSSL="${pkgs.openssl}/bin/openssl"
            # tar -z spawns gzip as a child; it's not on the activation PATH.
            export PATH="${pkgs.gzip}/bin:$PATH"
            TG_TOKEN="$(cat ${config.sops.secrets."services/monitoring/telegram-bot-token".path})"
            TG_CHAT="$(cat ${config.sops.secrets."services/monitoring/telegram-chat-id".path})"
            GRAFANA_PW="$(cat ${config.sops.secrets."services/monitoring/grafana-admin-password".path})"
            LITELLM_MASTER="$(cat ${config.sops.secrets."services/ai/litellm/master-key".path})"
            PG_PASSWORD="$(cat ${config.sops.secrets."services/ai/litellm/postgres-password".path})"
            LITELLM_DB_URL="postgresql://litellm:$PG_PASSWORD@postgres.default.svc.cluster.local:5432/litellm"
            # Pod API key for llama.cpp /metrics auth: single source of truth is
            # the sops secret (litellm-keys/pod-api-key in the cluster). Not
            # grepped out of the rendered YAML — a chart change to the key's
            # wiring would yield an empty key and a silent --from-literal=token=""
            # (ai-fleet ServiceMonitor 401s, no error).
            POD_API_KEY="$(cat ${config.sops.secrets."services/ai/litellm/pod-api-key".path})"
            LLM_KEY="$POD_API_KEY"
            [ -n "$LLM_KEY" ] || { echo "error: services/ai/litellm/pod-api-key sops secret is empty" >&2; exit 1; }
            # Metrics key for the gateway /metrics scrape (dedicated key,
            # key_alias "metrics"; same rationale as the pod API key above).
            METRICS_KEY="$(cat ${config.sops.secrets."services/ai/litellm/metrics-key".path})"
            [ -n "$METRICS_KEY" ] || { echo "error: services/ai/litellm/metrics-key sops secret is empty" >&2; exit 1; }

            # Every resource this script applies carries the managed-by label,
            # and each `kubectl apply --prune` pass is scoped to it, so a prune
            # can never delete anything outside our charts (k3s built-ins,
            # other workloads). Each pass needs its own prune-group label:
            # `apply --prune -l` deletes EVERY resource matching the selector
            # that is not in that pass's file, so two passes sharing a
            # selector would delete each other's resources, and the pruner
            # only lists namespaced resources in the namespaces its file
            # visits. The kps CRDs are server-side applied (their
            # openAPIV3Schema overflows the client-side last-applied
            # annotation) and `--server-side --prune` is alpha/rejected, so
            # they get the managed label only and are applied without prune.
            MANAGED="app.kubernetes.io/managed-by=nixos-k3s"
            SEL_CLUSTER="$MANAGED,mjolnir/prune-group=cluster"
            SEL_DEFAULT="$MANAGED,mjolnir/prune-group=default"
            SEL_MONITORING="$MANAGED,mjolnir/prune-group=monitoring"
            SEL_KUBE_SYSTEM="$MANAGED,mjolnir/prune-group=kube-system"
            # Kinds a prune pass may delete. kubectl's default allowlist has
            # no CRs, so the monitoring.coreos.com kinds must be listed.
            PRUNE_ALLOWLIST=(
              core/v1/ConfigMap core/v1/Secret core/v1/Service core/v1/PersistentVolumeClaim core/v1/Pod core/v1/Endpoints
              apps/v1/Deployment apps/v1/DaemonSet apps/v1/StatefulSet apps/v1/ReplicaSet
              batch/v1/Job networking.k8s.io/v1/Ingress networking.k8s.io/v1/NetworkPolicy
              rbac.authorization.k8s.io/v1/ClusterRole rbac.authorization.k8s.io/v1/ClusterRoleBinding
              admissionregistration.k8s.io/v1/ValidatingWebhookConfiguration admissionregistration.k8s.io/v1/MutatingWebhookConfiguration
              monitoring.coreos.com/v1/PrometheusRule monitoring.coreos.com/v1/ServiceMonitor monitoring.coreos.com/v1/Prometheus monitoring.coreos.com/v1/Alertmanager monitoring.coreos.com/v1/PodMonitor
            )
            # $1 = prune group, $2 = jq select, remaining args = manifest
            # files. Stamps every doc (and every item of a v1 List) with the
            # managed-by + prune-group labels.
            # -y --explicit-start: emit YAML with a --- per document. The
            # python yq defaults to a JSON stream (concatenated objects, no
            # separators), which kubectl apply rejects ("apiVersion not set,
            # kind not set").
            # select(.apiVersion != null): drop comment-only docs that helm
            # leaves behind for disabled templates (e.g. dcgm-exporter's
            # tls-secret / web-config) — they have no apiVersion and kubectl
            # rejects them.
            label_all() {
              local group="$1" sel="$2"
              shift 2
              "$YQ" -y --explicit-start "select($sel) | select(.apiVersion != null) | (if .kind == \"List\" then .items |= map(.metadata.labels = ((.metadata.labels // {}) + {\"app.kubernetes.io/managed-by\":\"nixos-k3s\",\"mjolnir/prune-group\":\"$group\"})) else .metadata.labels = ((.metadata.labels // {}) + {\"app.kubernetes.io/managed-by\":\"nixos-k3s\",\"mjolnir/prune-group\":\"$group\"}) end)" "$@"
            }
            # Managed label only (kps CRDs: outside the prune scope, see above).
            label_managed() {
              "$YQ" -y --explicit-start "select(.apiVersion != null) | .metadata.labels = ((.metadata.labels // {}) + {\"app.kubernetes.io/managed-by\":\"nixos-k3s\"})" "$@"
            }
            # apply --prune scoped to $1 (selector) and $2 (namespace; empty =
            # cluster scope); remaining args = manifest files.
            apply_pruned() {
              local sel="$1" ns="$2"
              shift 2
              local pargs=() fargs=()
              for r in "''${PRUNE_ALLOWLIST[@]}"; do pargs+=("--prune-allowlist=$r"); done
              # kubectl apply needs -f for each manifest file (positional args
              # are rejected: "Unexpected args").
              for f in "$@"; do fargs+=("-f" "$f"); done
              if [ -n "$ns" ]; then
                $KCTL apply --prune -n "$ns" -l "$sel" "''${pargs[@]}" "''${fargs[@]}"
              else
                $KCTL apply --prune -l "$sel" "''${pargs[@]}" "''${fargs[@]}"
              fi
            }

            # Fill the sops placeholders in the values, render kps, and build the
            # grafana admin Secret. Done in a temp dir so nothing leaks to the store.
            T=$(mktemp -d)
            trap 'rm -rf "$T"' EXIT
            # envsubst fills the sops placeholders (sed broke on tokens
            # containing |, & or \). The SHELL-FORMAT arg restricts
            # substitution to the two placeholders, so any other $ in the
            # values file is left alone.
            $ENVSUBST "''${TELEGRAM_BOT_TOKEN} ''${TELEGRAM_CHAT_ID}" < "$KPS_VALUES_SRC" > "$T/kps-values.yaml"
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
            # controllers forever, so restart it after the CRDs are in place —
            # but only when the CRDs were newly created (a restart on every
            # activation would flap the operator for no reason).
            #
            # Label + split every manifest by prune scope. The kps render
            # spans monitoring/ (workloads + CRs), kube-system/ (the coredns
            # Service) and cluster scope (CRs/CRBs/webhooks); the v1 List
            # (additionalServiceMonitors) is all-monitoring and stays whole.
            label_managed "$KPS_CRDS"/* > "$T/crds.json"
            label_all monitoring ".kind == \"List\" or .metadata.namespace == \"monitoring\"" "$T/kps-rendered.yaml" > "$T/monitoring-kps.json"
            label_all kube-system ".metadata.namespace == \"kube-system\"" "$T/kps-rendered.yaml" > "$T/kube-system-kps.json"
            label_all cluster ".kind != \"List\" and .metadata.namespace == null" "$T/kps-rendered.yaml" > "$T/cluster-kps.json"
            # kubelet SA (monitoring/) + RBAC (cluster scope) split.
            label_all monitoring ".kind == \"ServiceAccount\"" ${k8sDir}/manifests/kubelet-monitoring.yaml > "$T/monitoring-kubelet-sa.json"
            label_all cluster ".kind == \"ClusterRoleBinding\"" ${k8sDir}/manifests/kubelet-monitoring.yaml > "$T/cluster-kubelet-crb.json"
            label_all default "true" ${aiChartRendered}/rendered.yaml > "$T/default-ai.json"
            label_all monitoring "true" ${monitoringChartRendered.loki}/rendered.yaml ${monitoringChartRendered.alloy}/rendered.yaml ${monitoringChartRendered.dcgm}/rendered.yaml ${k8sDir}/manifests/cloud-model-rates.yaml ${k8sDir}/manifests/dcgm-networkpolicy.yaml > "$T/monitoring-charts.json"
            cat "$T/cluster-kps.json" "$T/cluster-kubelet-crb.json" > "$T/cluster.yaml"
            cat "$T/monitoring-kubelet-sa.json" "$T/monitoring-kps.json" "$T/monitoring-charts.json" > "$T/monitoring-static.json"
            cat "$T/kube-system-kps.json" > "$T/kube-system.yaml"

            for i in $(seq 1 30); do
              $KCTL get namespace monitoring >/dev/null 2>&1 || $KCTL create namespace monitoring
              # PSS privileged on the monitoring namespace (P2-36): the DCGM
              # exporter runs as root + SYS_ADMIN (CDI) and the alloy daemonset
              # mounts a hostPath volume for /var/log (llama.log tailing) —
              # both need more than baseline. label --overwrite is idempotent,
              # so an existing namespace gets the label too.
              $KCTL label namespace monitoring pod-security.kubernetes.io/enforce=privileged --overwrite
              # Migration: older deploys applied three kubernetes-system
              # PrometheusRules (controller-manager/kube-proxy/scheduler) that
              # are now disabled in values. They carry no managed label, so
              # the prune below cannot see them; label them so the monitoring
              # pass prunes them. Once gone this is a silent no-op.
              for r in kps-kube-prometheus-stack-kubernetes-system-controller-manager \
                       kps-kube-prometheus-stack-kubernetes-system-kube-proxy \
                       kps-kube-prometheus-stack-kubernetes-system-scheduler; do
                $KCTL label prometheusrule -n monitoring "$r" "$MANAGED" \
                    "mjolnir/prune-group=monitoring" --overwrite >/dev/null 2>&1 || true
              done
              # kubelet SA + RBAC (system:node-reader) must exist before its
              # token is minted (k8s 1.24+ no longer auto-creates SA token
              # secrets). The token is minted for 10 years — accepted
              # trade-off for a single-node homelab: a shorter TTL would need
              # re-mint machinery (a controller or a deploy hook that renews
              # the Secret) which we deliberately don't run. The SA is applied
              # WITHOUT --prune (the monitoring pass covers deletion) so a
              # fresh install gets it before the token mint.
              # grafana admin creds as a proper K8s Secret (idempotent apply);
              # llm-api-key: the pod API key for llama.cpp /metrics auth;
              # litellm-metrics-key: the dedicated key for the gateway /metrics
              # scrape (both from the sops secrets above).
              # Fresh-install detection: the operator needs a restart only if
              # any CRD was missing before this apply (see above).
              CRDS_NEW=0
              for f in "$KPS_CRDS"/*; do
                $KCTL get crd "$($YQ -r '.metadata.name' "$f")" >/dev/null 2>&1 || CRDS_NEW=1
              done
              # Grafana dashboards: the sidecar picks up any ConfigMap in this
              # namespace labelled grafana_dashboard (labelValue empty = any).
              # litellm-keys (default ns): master key + postgres password + the
              # full DATABASE_URL (password embedded). The gateway pod reads
              # database-url + master-key; the postgres pod reads postgres-password.
              # grafana-tls (P2-37): self-signed cert for grafana.mjolnir, long-lived
              # (10y). The cert/key are untracked and regenerated on every activation
              # (acceptable: the browser shows a self-signed warning on first use
              # regardless, and the LAN is trusted). Regenerating keeps the Secret in
              # the prune scope every pass, so it is never orphaned.
              $OPENSSL req -x509 -newkey rsa:2048 -nodes \
                  -keyout "$T/grafana-tls.key" \
                  -out "$T/grafana-tls.crt" \
                  -days 3650 \
                  -subj "/CN=grafana.mjolnir" \
                  -addext "subjectAltName=DNS:grafana.mjolnir"
              $KCTL create secret tls grafana-tls \
                  --namespace monitoring \
                  --cert="$T/grafana-tls.crt" \
                  --key="$T/grafana-tls.key" \
                  --dry-run=client -o yaml | label_all monitoring "true" > "$T/monitoring-grafana-tls.json"
              $KCTL apply -f "$T/monitoring-kubelet-sa.json" \
                && $KCTL create token kubelet-monitoring --namespace monitoring \
                    --duration=87600h > "$T/kubelet-token" \
                && $KCTL create secret generic kubelet-monitoring-token \
                    --namespace monitoring \
                    --from-file=token="$T/kubelet-token" \
                    --dry-run=client -o yaml | label_all monitoring "true" > "$T/monitoring-kubelet-token.json" \
                && $KCTL create secret generic litellm-keys \
                    --namespace default \
                    --from-literal=master-key="$LITELLM_MASTER" \
                    --from-literal=postgres-password="$PG_PASSWORD" \
                    --from-literal=database-url="$LITELLM_DB_URL" \
                    --from-literal=pod-api-key="$POD_API_KEY" \
                    --dry-run=client -o yaml | label_all default "true" > "$T/default-litellm-keys.json" \
                && $KCTL create secret generic monitoring-secrets \
                    --namespace monitoring \
                    --from-literal=admin-user=admin \
                    --from-literal=admin-password="$GRAFANA_PW" \
                    --dry-run=client -o yaml | label_all monitoring "true" > "$T/monitoring-secrets.json" \
                && $KCTL create secret generic llm-api-key \
                    --namespace monitoring \
                    --from-literal=token="$LLM_KEY" \
                    --dry-run=client -o yaml | label_all monitoring "true" > "$T/monitoring-llm-api-key.json" \
                && $KCTL create secret generic litellm-metrics-key \
                    --namespace monitoring \
                    --from-literal=token="$METRICS_KEY" \
                    --dry-run=client -o yaml | label_all monitoring "true" > "$T/monitoring-litellm-metrics-key.json" \
                && $KCTL create configmap mjolnir-dashboards \
                    --namespace monitoring \
                    --from-file=cluster-overview.json=${k8sDir}/apps/monitoring/dashboards/cluster-overview.json \
                    --from-file=llm-fleet.json=${k8sDir}/apps/monitoring/dashboards/llm-fleet.json \
                    --from-file=llm-overview.json=${k8sDir}/apps/monitoring/dashboards/llm-overview.json \
                    --dry-run=client -o yaml | label_all monitoring "true" > "$T/monitoring-dashboards.json" \
                && cat "$T/monitoring-static.json" "$T/monitoring-kubelet-token.json" \
                    "$T/monitoring-secrets.json" "$T/monitoring-llm-api-key.json" \
                    "$T/monitoring-litellm-metrics-key.json" \
                    "$T/monitoring-grafana-tls.json" \
                    "$T/monitoring-dashboards.json" > "$T/monitoring.yaml" \
                && cat "$T/default-ai.json" "$T/default-litellm-keys.json" > "$T/default.yaml" \
                && $KCTL apply --server-side --force-conflicts -f "$T/crds.json" \
                && apply_pruned "$SEL_CLUSTER" "" "$T/cluster.yaml" \
                && apply_pruned "$SEL_DEFAULT" "default" "$T/default.yaml" \
                && apply_pruned "$SEL_MONITORING" "monitoring" "$T/monitoring.yaml" \
                && apply_pruned "$SEL_KUBE_SYSTEM" "kube-system" "$T/kube-system.yaml" \
                && $KCTL label configmap mjolnir-dashboards --namespace monitoring grafana_dashboard=1 --overwrite \
                && { if [ "$CRDS_NEW" -eq 1 ]; then
                    $KCTL rollout restart deploy/kps-kube-prometheus-stack-operator --namespace monitoring
                  fi
                  exit 0
                }
              sleep 2
            done
            echo "error: chart apply failed after 60s" >&2
            exit 1
          '';
        };

        # 6443: k3s API server. 9100: node-exporter, 10250: kubelet — both
        # are hostNetwork on the node and scraped by Prometheus from the pod
        # network, so the INPUT chain must let the pod CIDR reach them.
        # allowedTCPPorts has no source restriction, so 9100/10250 get an
        # explicit nftables rule scoped to the pod CIDR (k3s' default
        # cluster-cidr) instead.
        networking.firewall.allowedTCPPorts = [ 6443 ];
        # extraInputRules is appended to the input-allow chain (nftables
        # backend; extraCommands is iptables-only and asserts here).
        networking.firewall.extraInputRules = ''
          tcp dport { 9100, 10250 } ip saddr 10.42.0.0/16 accept
        '';
        # NOTE: the LiteLLM gateway's hostPort 8000 is NOT covered by the
        # firewall above — hostPort traffic is DNAT'd via PREROUTING to the
        # pod CNI interface and never traverses the INPUT chain that
        # networking.firewall controls. The pods themselves are ClusterIP-only
        # and require the
        # --api-key set in the chart.
      };
    };
}
