{ inputs, ... }:
{
  flake.modules.nixos.k3s =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.k3s;
      # k8s/ lives at the repo root; this module is in nix/services/.
      k8sDir = ../../k8s;
      # k3s' default cluster-cidr. The nix k3s module exposes no cluster-cidr
      # option, so this literal is the single source of truth for both the
      # nftables rule below and the activation script's divergence check.
      clusterCidr = "10.42.0.0/16";
      # nvidia-container-runtime in CDI mode: reads the host's nvidia CDI spec
      # (which carries the nix-store driver-lib mounts + the nvidia-cdi-hook) and
      # injects the GPU selected by NVIDIA_VISIBLE_DEVICES. The hook-mode runtime
      # is unusable here (it needs nvidia-ctk inside the container, which the nix
      # store doesn't provide). Lives in the toolkit's `tools` output.
      nvidiaRuntime = "${pkgs.nvidia-container-toolkit.tools}/bin/nvidia-container-runtime.cdi";
      # Values overlay carrying the store path of the strata bundle THIS config
      # builds. Injected into the chart render above, so the pod's bundle path is
      # produced by the build instead of transcribed into a values file.
      #
      # Why that matters more than it looks. While the path was a literal in
      # k8s/apps/ai/values/, nothing in the Nix graph referenced the bundle: a
      # system generation is NOT a reference to paths merely mentioned in its
      # scripts (verified - nix-store -q --references on the last two system
      # profiles showed zero strata hits). Three separate mechanisms existed to
      # work around that one omission: a hand-maintained pin that drifted
      # silently, a CI job to notice the drift, and a manual GC root to stop the
      # path being collected out from under a running pod. With the path flowing
      # through the render, aiChartRendered takes the bundle as a build input, so
      # the generation that produced it retains it and a rollback still has the
      # bundle its pod was built against.
      #
      # Empty on hosts that build no strata bundle; the chart then refuses to
      # render a strata model rather than mounting an empty path.
      strataBundleValuesText = ''
        strataBundle: ${builtins.unsafeDiscardStringContext cfg.aiChart.strataBundle}
      '';
      # Same rule for the swap head-end bundle (llama-swap + swapk8s): the store
      # path travels through the render, so the generation that produced it - and
      # the one before it, which is what a rollback needs - both retain it. Empty
      # means this host builds no head-end, and the chart renders none.
      headEndValuesText = ''
        headEnd:
          bundle: ${builtins.unsafeDiscardStringContext cfg.aiChart.headEndBundle}
      '';
      # The wiki's numeric ids, volume size and host path exist once, here. The
      # chart reads them by --set, the host directories by tmpfiles below, and
      # the static PV by generation — three consumers in three languages (helm,
      # systemd, k3s' manifest loader) that nothing else connects. Drift is
      # quiet in both directions: a pod running as an id that cannot write the
      # directory it mounts, and a claim larger than its pre-bound PV sitting
      # Pending with an event that names no file.
      wikiStorage = {
        hostPath = "/var/lib/wiki";
        # 983 is unassigned on mjolnir; 999 is the image's own user.
        bookstackUid = 983;
        bookstackGid = 983;
        databaseUid = 999;
        databaseGid = 999;
        size = "10Gi";
        storageClass = "wiki-data";
        claimName = "wiki-data";
        claimNamespace = "wiki";
      };
      # The `bookstack` Secret's keys, in one place. The shell variable, the sops
      # path, the 0600 temp file and the --from-file argument are each derived
      # from the key, and the same list reaches the chart as `secret.keys`, where
      # every secretKeyRef is a lookup that fails the render when the key is
      # absent. A key the chart references and this module does not create is a
      # render error, not a pod wedged in CreateContainerConfigError.
      wikiSecretKeys = [ "APP_KEY" "DB_PASSWORD" "OIDC_CLIENT_ID" "OIDC_CLIENT_SECRET" ];
      # The sops secret name and the temp file name are both the key lower-cased
      # with hyphens.
      wikiSecretName = key: lib.replaceStrings [ "_" ] [ "-" ] (lib.toLower key);
      wikiSecretReads = lib.concatMapStringsSep "\n"
        (k: ''${"WIKI_${k}"}="$(cat ${config.sops.secrets."services/wiki/${wikiSecretName k}".path})"'')
        wikiSecretKeys;
      wikiSecretSentinelPairs = lib.concatMapStringsSep " "
        (k: "\"${wikiSecretName k}:$WIKI_${k}\"")
        wikiSecretKeys;
      wikiSecretFiles = lib.concatMapStringsSep "\n"
        (k: "    printf '%s' \"$WIKI_${k}\" > \"$T/secret-wiki-${wikiSecretName k}\"")
        wikiSecretKeys;
      wikiSecretFromArgs = lib.concatStrings (map
        (k: " \\\n                    --from-file=${k}=\"$T/secret-wiki-${wikiSecretName k}\"")
        wikiSecretKeys);
      wikiValuesText = ''
        bookstack:
          uid: ${toString wikiStorage.bookstackUid}
          gid: ${toString wikiStorage.bookstackGid}
        database:
          uid: ${toString wikiStorage.databaseUid}
          gid: ${toString wikiStorage.databaseGid}
        persistence:
          size: ${wikiStorage.size}
          claimName: ${wikiStorage.claimName}
          storageClass: ${wikiStorage.storageClass}
        secret:
          keys:
        ${lib.concatMapStringsSep "\n" (k: "    - ${k}") wikiSecretKeys}
        oidc:
          issuer: ${inputs.self.lib.issuerUrl}
          egressCidrs:
        ${lib.concatMapStringsSep "\n" (c: "    - ${c}") cfg.wikiOidcEgressCidrs}
      '';
      # The PV is generated rather than checked against the claim: it is
      # pre-bound by claimRef, so a capacity below the claim's request never
      # binds and never errors.
      wikiPvManifest = pkgs.writeText "wiki-local-pv.yaml" ''
        # Generated from `wikiStorage` in nix/services/k3s.nix, which also owns
        # the host subdirectories and the claim this volume binds to.
        #
        # Local, not NFS: a database on NFS is a latency story nobody needs. Not a
        # hostPath volume in the pod, which would break the namespace's Pod
        # Security posture.
        #
        # ONE volume, TWO mounts: the chart mounts it twice with subPath (mysql/
        # for the database, bookstack/ for the app's /config). A database-only
        # volume loses every uploaded image on a pod delete, and loses it quietly,
        # because a node-pinned volume reschedules so rarely that nobody sees it
        # happen.
        apiVersion: v1
        kind: PersistentVolume
        metadata:
          name: ${wikiStorage.claimName}
          labels:
            app.kubernetes.io/part-of: wiki
        spec:
          capacity:
            storage: ${wikiStorage.size}
          accessModes:
            - ReadWriteOnce
          # The only copy of the wiki's content until the backup timer exists: a
          # deleted PVC must not also delete the data.
          persistentVolumeReclaimPolicy: Retain
          storageClassName: ${wikiStorage.storageClass}
          # Pre-bound to the wiki claim: while this PV sat Available, any claim
          # in any namespace asking for this storage class could have won it,
          # and on a single-node cluster the node affinity would never have
          # refused them.
          claimRef:
            namespace: ${wikiStorage.claimNamespace}
            name: ${wikiStorage.claimName}
          local:
            path: ${wikiStorage.hostPath}
          nodeAffinity:
            required:
              nodeSelectorTerms:
                - matchExpressions:
                    # The stable `storage` label, not kubernetes.io/hostname: a
                    # node rename would otherwise orphan the volume.
                    - key: storage
                      operator: In
                      values:
                        - mjolnir
      '';
      # A directory under k8s/apps/ is an app chart when it carries a Chart.yaml.
      # `just k8s-render` and the CI preview render apply the same rule, so an
      # app cannot be discovered by one of the three and missed by another.
      # NOTE (h1j.1, 2026-09-24): we deliberately do NOT use
      # services.k3s.autoDeployCharts — it only takes a remote-repo URL or a
      # pre-packaged .tgz with a SINGLE values source, and can't do a local
      # unpacked chart + 9 merged -f values files + .Files.Get. See
      # docs/h1j.1-autodeploycharts.md. Use autoDeployCharts for future
      # remote-repo charts only.
      appCharts = builtins.filter (
        name: builtins.pathExists (k8sDir + "/apps/${name}/Chart.yaml")
      ) (builtins.attrNames (builtins.readDir (k8sDir + "/apps")));

      # The values a build supplies rather than the chart: a store path or a host
      # fact that must enter the render so the generation retains it, and so the
      # host and the manifest cannot disagree. Held as text so a preview can eval
      # it without building; a chart absent from this list renders with no extras,
      # and the charts that need one `required` those values, so forgetting an
      # entry fails the render instead of passing quietly.
      # The values a build supplies rather than the chart, as text.
      #
      # `unsafeDiscardStringContext` on the two bundle paths is what lets
      # `nix eval .#...appChartValues.ai` work at all: a string carrying a store
      # path's context makes nix realise that derivation, and the swap head-end is
      # a dynamic derivation, so the eval dies on `dynamic-derivations is
      # disabled`. Dropping the context costs nothing here — the garbage-collector
      # link this design depends on is the store path appearing in the writeText
      # derivation's `text`, which `aiChartRendered` then takes as an input drv.
      # That is a property of the store graph, not of eval-time string context.
      chartBuildValuesText = {
        # The strata bundle is BUILT here, not pinned in a values file: this is
        # what links config.system.build.strata into the pod. See
        # strataBundleValuesText above for why that link is the whole design.
        ai = strataBundleValuesText + headEndValuesText;
        wiki = wikiValuesText;
      };

      chartBuildValues = lib.mapAttrs (
        name: text: pkgs.writeText "${name}-build-values.yaml" text
      ) chartBuildValuesText;

      renderAppChart =
        name:
        pkgs.runCommand "${name}-chart-rendered"
          {
            src = k8sDir;
            nativeBuildInputs = [ pkgs.kubernetes-helm ];
          }
          ''
            mkdir -p $out
            # one -f per values file (a bare glob expands to positional chart args)
            F=(-f $src/apps/${name}/values.yaml)
            for f in $src/apps/${name}/values/*.yaml; do F+=(-f "$f"); done
            ${lib.optionalString (chartBuildValues ? ${name}) ''F+=(-f ${chartBuildValues.${name}})''}
            helm template ${name} $src/apps/${name} "''${F[@]}" > $out/rendered.yaml
          '';

      appChartRenders = lib.genAttrs appCharts renderAppChart;

      # curl for the oneshot below (the metrics-key registration talks to the
      # gateway's /metrics + /key/generate over HTTP). Wrapped in a
      # single-output script because interpolating curl's default `bin`
      # output directly into the oneshot's script string produces a named-output
      # string-context element that `nix eval --raw/--write-to` on the script
      # attribute chokes on (Bad String Context element); the wrapper's `out`
      # output keeps the oneshot's context uniformly `!out!`. Runs on the
      # target (remoteBuild), like the render derivations above.
      scrapeCurl = pkgs.writeShellScript "scrape-curl" ''
        exec ${pkgs.curl}/bin/curl "$@"
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
        # dcgm runs in the dedicated gpu/ namespace (PSS privileged: it needs
        # root + SYS_ADMIN for the CDI GPU driver); loki/alloy stay in
        # monitoring/ (PSS baseline is enough — alloy's hostPath /var/log/pods
        # is allowed at baseline).
        dcgm = {
          release = "dcgm-exporter";
          chart = "${dcgmChartSrc}/deployment";
          values = "${k8sDir}/apps/monitoring/values/dcgm-exporter.yaml";
          namespace = "gpu";
        };
        loki = {
          release = "loki";
          chart = lokiChart;
          values = "${k8sDir}/apps/monitoring/values/loki.yaml";
          namespace = "monitoring";
        };
        alloy = {
          release = "alloy";
          chart = alloyChart;
          values = "${k8sDir}/apps/monitoring/values/alloy.yaml";
          namespace = "monitoring";
        };
      };
      monitoringChartRendered = lib.mapAttrs (
        name:
        {
          release,
          chart,
          values,
          namespace,
        }:
        pkgs.runCommand "${name}-chart-rendered"
          {
            nativeBuildInputs = [ pkgs.kubernetes-helm ];
          }
          ''
            mkdir -p $out
            helm template ${release} ${chart} \
              -f ${values} \
              --namespace ${namespace} > $out/rendered.yaml
          ''
      ) monitoringCharts;
    in
    {
      options.services.k3s.appChartValues = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        internal = true;
        description = ''
          Per app chart, the values YAML this build supplies rather than the
          chart: store paths and host facts the render has to own. Set by this
          module. `just k8s-render` and the CI preview eval it and apply the same
          text, so a preview cannot render something other than what the deploy
          applies, and neither has to build anything to get it:
          `nix eval .#nixosConfigurations.<host>.config.services.k3s.appChartValues.<chart>`.
        '';
      };

      options.services.k3s.wikiOidcEgressCidrs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          IPv4 /32 host routes the BookStack pod may reach on TCP/443: the OIDC
          issuer's address, which the pod resolves through public DNS and so
          leaves the cluster for the edge. k3s' kube-router policy controller has
          no FQDN or L7 rules, so a hostname cannot be expressed at all.

          An empty list is a wildcard, not a refusal - a NetworkPolicy egress rule
          with no peer matches every destination - so the chart fails the render on
          empty, and templates/networkpolicy.yaml refuses anything wider than a /32.
          The address belongs to a VPS, so it can go stale with no commit here; the
          wiki chart's wiki-oidc-egress CronJob re-tests the whole path from inside
          the namespace and alerts on failure.
        '';
      };

      options.services.k3s.aiChart = {
        strataBundle = lib.mkOption {
          type = lib.types.str;
          default = "";
          example = "/nix/store/xxxx-strata-0.1.40.3";
          description = ''
            Store path of the Strata engine bundle to render into the ai chart's
            strata model pods. Set it to config.system.build.strata on a host
            that builds one; the render then references the bundle, which is what
            keeps it out of the garbage collector's reach. Left empty, any
            enabled engine: strata model fails to render rather than mounting an
            empty path.
          '';
        };
        headEndBundle = lib.mkOption {
          type = lib.types.str;
          default = "";
          example = "/nix/store/xxxx-swap-head-end-0.1.0";
          description = ''
            Store path of the swap head-end bundle (llama-swap plus the swapk8s
            shim) that on-demand model pods are driven by. Set it to
            config.system.build.swapHeadEnd on a host that builds one; the bundle
            then reaches the pod through the render instead of through a path
            transcribed into a values file, which is the same rule the strata
            bundle follows and for the same reason. Left empty, no head-end is
            rendered and every model keeps the static lifecycle it has today.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        # Host dir for the Postgres static PV (LiteLLM key store). Pre-owned by
        # uid 999 (the postgres image user) so the non-root pod can write it —
        # the cluster's non-root policy forbids a root chown initContainer, and
        # local-path PVs are root-owned. See k8s/manifests/local-pvs.yaml.
        systemd.tmpfiles.rules = [
          "d /var/lib/postgres-data 0700 999 999 -"
          # The wiki's PV is one host directory mounted into both workloads by
          # subPath, so both subdirectories are pre-owned here. Same reason as
          # postgres above: these pods cannot chown for themselves, and
          # BookStack's own root-at-init chown runs on a directory it first has
          # to be able to write.
          "d ${wikiStorage.hostPath} 0755 root root -"
          "d ${wikiStorage.hostPath}/mysql 0750 ${toString wikiStorage.databaseUid} ${toString wikiStorage.databaseGid} -"
          "d ${wikiStorage.hostPath}/bookstack 0770 ${toString wikiStorage.bookstackUid} ${toString wikiStorage.bookstackGid} -"
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
          # Wiki (BookStack). Deliberately a different sops file from every
          # secret above: homelab-wiki-secrets.yaml is encrypted to the human
          # and mjolnir only, so the wiki's database password and OIDC client
          # secret are not decryptable on roque, which holds the IdP, the NAS
          # mount and n8n's credential store.
          "services/wiki/app-key" = {
            sopsFile = ./homelab/homelab-wiki-secrets.yaml;
          };
          "services/wiki/db-password" = {
            sopsFile = ./homelab/homelab-wiki-secrets.yaml;
          };
          "services/wiki/oidc-client-id" = {
            sopsFile = ./homelab/homelab-wiki-secrets.yaml;
          };
          "services/wiki/oidc-client-secret" = {
            sopsFile = ./homelab/homelab-wiki-secrets.yaml;
          };
        };
        # Materialise secrets in the activation script (setupSecrets) instead of
        # a systemd oneshot at boot — the aiChart activation script below reads
        # them and must run after they exist.
        sops.useSystemdActivation = false;

        services.k3s = {
          role = "server";
          appChartValues = chartBuildValuesText;
          # Lean: no metrics-server (model pods expose their own --metrics later).
          # traefik + coredns kept (LAN-name ingress).
          disable = [ "metrics-server" ];

          # Stable label for the local PVs' nodeAffinity
          # (k8s/manifests/local-pvs.yaml): selecting on kubernetes.io/hostname
          # would orphan all PVs on a node rename.
          # nvidia.com/gpu.present=true is the conventional GPU-node label the
          # dcgm-exporter chart's daemonset nodeSelector matches on (the
          # nvidia-container-toolkit only sets nixos-nvidia-cdi=enabled, which
          # the chart doesn't know about — without this label DCGM schedules 0
          # replicas). Set here so it's stable and under our control.
          nodeLabel = [
            "storage=mjolnir"
            "nvidia.com/gpu.present=true"
          ];

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
            wiki-pvs = {
              source = wikiPvManifest;
            };
          };
        };

        # Expose the rendered charts as toplevel dependencies so they land in
        # the system closure. The activation script below references them only
        # inside strings, which Nix does NOT track as a dependency on its own —
        # without this the paths are never built and the apply fails at deploy
        # time.
        system.build =
          {
            # kps chart (fetched .tgz) — rendered at activation, not build time.
            kpsChart = kpsChart;
          }
          // lib.mapAttrs' (
            name: chart: lib.nameValuePair "${name}ChartRendered" chart
          ) (appChartRenders // monitoringChartRendered);

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
            RemainAfterExit = true;
          };
          # k3s + helm + envsubst aren't on the oneshot's default PATH, so use
          # full binary paths. Runs after sops-nix materialises /run/secrets
          # (setupSecrets, in the activation phase) and after k3s is up.
          script = ''
            KCTL="${pkgs.k3s}/bin/k3s kubectl"
            CLUSTER_CIDR="${clusterCidr}"
            CURL="${scrapeCurl}"
            HELM="${pkgs.kubernetes-helm}/bin/helm"
            KPS_CHART="${kpsChart}"
            KPS_VALUES_SRC="${k8sDir}/apps/monitoring/values/kube-prometheus-stack.yaml"
            ENVSUBST="${pkgs.envsubst}/bin/envsubst"
            TAR="${pkgs.gnutar}/bin/tar"
            YQ="${pkgs.yq}/bin/yq"
            OPENSSL="${pkgs.openssl}/bin/openssl"
            # tar -z spawns gzip as a child; it's not on the activation PATH.
            export PATH="${pkgs.gzip}/bin:$PATH"
            # pipefail: the create secret | label_all pipelines below must
            # fail if kubectl fails — label_all succeeds on empty input, so
            # without pipefail a failed create would leave an empty file and
            # the next apply pass would prune a live Secret.
            set -o pipefail
            # Exported: envsubst below reads them from the environment.
            export TELEGRAM_BOT_TOKEN="$(cat ${
              config.sops.secrets."services/monitoring/telegram-bot-token".path
            })"
            export TELEGRAM_CHAT_ID="$(cat ${config.sops.secrets."services/monitoring/telegram-chat-id".path})"
            [ -n "$TELEGRAM_BOT_TOKEN" ] || { echo "error: services/monitoring/telegram-bot-token sops secret is empty" >&2; exit 1; }
            [ -n "$TELEGRAM_CHAT_ID" ] || { echo "error: services/monitoring/telegram-chat-id sops secret is empty" >&2; exit 1; }
            GRAFANA_PW="$(cat ${config.sops.secrets."services/monitoring/grafana-admin-password".path})"
            LITELLM_MASTER="$(cat ${config.sops.secrets."services/ai/litellm/master-key".path})"
            PG_PASSWORD="$(cat ${config.sops.secrets."services/ai/litellm/postgres-password".path})"
            [ -n "$GRAFANA_PW" ] || { echo "error: services/monitoring/grafana-admin-password sops secret is empty" >&2; exit 1; }
            [ -n "$LITELLM_MASTER" ] || { echo "error: services/ai/litellm/master-key sops secret is empty" >&2; exit 1; }
            [ -n "$PG_PASSWORD" ] || { echo "error: services/ai/litellm/postgres-password sops secret is empty" >&2; exit 1; }
            # Percent-encode the password before embedding it in the DSN: an
            # unencoded @ : / % # in the sops value would malform the URL and
            # the gateway would silently lose its key store.
            urlencode() {
              local LC_ALL=C
              local s="$1" out="" c i
              for (( i=0; i<''${#s}; i++ )); do
                c="''${s:i:1}"
                case "$c" in
                  [a-zA-Z0-9.~_-]) out+="$c" ;;
                  *) out+="$(printf '%%%02X' "'$c")" ;;
                esac
              done
              printf '%s' "$out"
            }
            LITELLM_DB_URL="postgresql://litellm:$(urlencode "$PG_PASSWORD")@postgres.default.svc.cluster.local:5432/litellm"
            # Pod API key for llama.cpp /metrics auth: single source of truth is
            # the sops secret (litellm-keys/pod-api-key in the cluster). Not
            # grepped out of the rendered YAML — a chart change to the key's
            # wiring would yield an empty key and a silent --from-literal=token=""
            # (ai-fleet ServiceMonitor 401s, no error).
            POD_API_KEY="$(cat ${config.sops.secrets."services/ai/litellm/pod-api-key".path})"
            [ -n "$POD_API_KEY" ] || { echo "error: services/ai/litellm/pod-api-key sops secret is empty" >&2; exit 1; }
            # Metrics key for the gateway /metrics scrape (dedicated key,
            # key_alias "metrics"; same rationale as the pod API key above).
            METRICS_KEY="$(cat ${config.sops.secrets."services/ai/litellm/metrics-key".path})"
            [ -n "$METRICS_KEY" ] || { echo "error: services/ai/litellm/metrics-key sops secret is empty" >&2; exit 1; }

            # Wiki secrets. The Pocket ID OIDC client is created by hand, so a
            # fresh scope ships the two client values as the literal string
            # "unset". All four values below are read on activation and
            # judged on two separate states, and the two states fail
            # differently: the sentinel is an allowed configuration, so seeing
            # it skips the whole wiki pass, loudly, and everything else still
            # applies — deploying BookStack against a client that does not
            # exist produces a login redirect to an error page, which reads as
            # a broken wiki rather than an unconfigured one. An empty value is
            # never allowed either: it skips the wiki pass loudly (below) and
            # lets the rest of the generation land — the unit exits 0 — because
            # an empty secret is a mistake and not a state of the world.
            ${wikiSecretReads}
            WIKI_DEPLOY=1
            WIKI_SKIP_REASON=""
            WIKI_UNSET_SEEN=0
            for wv in ${wikiSecretSentinelPairs}; do
              [ -n "''${wv#*:}" ] || { echo "wiki: error: services/wiki sops secret ''${wv%%:*} is empty; skipping the wiki pass" >&2; WIKI_DEPLOY=0; WIKI_SKIP_REASON="''${WIKI_SKIP_REASON:+''$WIKI_SKIP_REASON; }sops secret ''${wv%%:*} is empty"; }
              [ "''${wv#*:}" = "unset" ] && [ "$WIKI_UNSET_SEEN" = "0" ] && { WIKI_DEPLOY=0; WIKI_UNSET_SEEN=1; WIKI_SKIP_REASON="''${WIKI_SKIP_REASON:+''$WIKI_SKIP_REASON; }OIDC client values are still the 'unset' sentinel; create the Pocket ID client, put its id and secret into nix/services/homelab/homelab-wiki-secrets.yaml, and re-activate"; }
            done

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
            SEL_GPU="$MANAGED,mjolnir/prune-group=gpu"
            SEL_WIKI="$MANAGED,mjolnir/prune-group=wiki"
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
            # $1 = file, $2 = the step that should have filled it. The wiki
            # pass is non-fatal, so a failure here must name its step: for an
            # empty document there is nothing in the output above — every
            # command in the pipeline can exit 0 on empty input, so the
            # generic guard line is the only signal an operator gets.
            nonempty() {
              local f="$1" step="$2"
              [ -s "$f" ] || { echo "error: $step left $f empty" >&2; return 1; }
            }

            # Idempotently ensure the gateway's key store knows the dedicated
            # metrics key. The litellm ServiceMonitor presents the sops
            # metrics-key value as a bearer token, but with
            # require_auth_for_metrics_endpoint the gateway checks the key
            # against its Postgres key store — a key that exists only in sops
            # gets 401 (the 2026-10-05 dashboards-outage root cause). A plain
            # virtual key is NOT enough: the /metrics route check is proxy-admin
            # only, and the sanctioned non-admin path is allowed_routes
            # (verified against litellm v1.102.1: /key/generate with the fixed
            # key value + allowed_routes ["/metrics"] -> /metrics/ 200).
            # Probes the gateway's hostPort 8000 directly (the oneshot runs on
            # the single node); the trailing slash matters (307 without it).
            # A fresh Postgres PVC self-heals: the key is re-registered on the
            # next activation. Returns non-zero on failure so the retry loop
            # below re-runs the (idempotent) applies and retries registration.
            register_metrics_key() {
              local gw="http://127.0.0.1:8000" code
              code="$($CURL -s -o /dev/null -w '%{http_code}' --max-time 10 \
                    -H "Authorization: Bearer $METRICS_KEY" "$gw/metrics/" 2>/dev/null)"
              [ "$code" = "200" ] && return 0
              # Register: fixed key value from sops (== the ServiceMonitor token),
              # alias "metrics", allowed_routes ["/metrics"]. Both keys go to
              # 0600 files (curl config + JSON bodies), never argv.
              # Two cases (both verified against v1.102.1):
              #   - key exists but lacks allowed_routes (registered without it,
              #     or sops value rotated onto an existing alias): /key/update
              #     sets the routes. /key/generate would 400 on the alias.
              #   - key absent entirely (fresh Postgres PVC): /key/generate with
              #     the fixed value mints it in one shot. /key/update would 404.
              # Try update first, fall through to generate on 404.
              ( umask 077
                printf 'header = "Authorization: Bearer %s"\n' "$LITELLM_MASTER" > "$T/gateway-curl.conf"
                printf '{"key":"%s","allowed_routes":["/metrics"]}' "$METRICS_KEY" \
                    > "$T/metrics-key-update.json"
                printf '{"key":"%s","key_alias":"metrics","allowed_routes":["/metrics"]}' "$METRICS_KEY" \
                    > "$T/metrics-key-register.json"
              )
              code="$($CURL -s -o /dev/null -w '%{http_code}' --max-time 10 \
                    -K "$T/gateway-curl.conf" -H "Content-Type: application/json" \
                    -d @"$T/metrics-key-update.json" "$gw/key/update" 2>/dev/null)"
              if [ "$code" != "200" ]; then
                code="$($CURL -s -o /dev/null -w '%{http_code}' --max-time 10 \
                      -K "$T/gateway-curl.conf" -H "Content-Type: application/json" \
                      -d @"$T/metrics-key-register.json" "$gw/key/generate" 2>/dev/null)"
              fi
              if [ "$code" != "200" ]; then
                echo "warning: metrics-key registration returned HTTP $code (will retry)" >&2
                return 1
              fi
              code="$($CURL -s -o /dev/null -w '%{http_code}' --max-time 10 \
                    -H "Authorization: Bearer $METRICS_KEY" "$gw/metrics/" 2>/dev/null)"
              if [ "$code" != "200" ]; then
                echo "warning: gateway still rejects the metrics key after registration (HTTP $code; will retry)" >&2
                return 1
              fi
              echo "metrics key registered with the gateway (key_alias: metrics)" >&2
              return 0
            }

            # Fill the sops placeholders in the values, render kps, and build the
            # grafana admin Secret. Done in a temp dir so nothing leaks to the store.
            T=$(mktemp -d)
            trap 'rm -rf "$T"' EXIT
            # Fail fast on render-phase failures: a failed render produces
            # empty files, and the monitoring prune pass below would then
            # delete EVERY managed resource in monitoring/ (the whole kps
            # stack). set -e covers the render section only; the apply loop
            # keeps its own retry semantics (set +e before it).
            set -e
            # envsubst fills the sops placeholders (sed broke on tokens
            # containing |, & or \). The SHELL-FORMAT arg restricts
            # substitution to the two placeholders, so any other $ in the
            # values file is left alone.
            $ENVSUBST "''${TELEGRAM_BOT_TOKEN} ''${TELEGRAM_CHAT_ID}" < "$KPS_VALUES_SRC" > "$T/kps-values.yaml"
            [ -s "$T/kps-values.yaml" ] || { echo "error: envsubst produced empty kps-values.yaml" >&2; exit 1; }
            # Render the kps templates (CRs + workloads) WITHOUT --include-crds;
            # the CRDs are extracted from the chart and applied separately below.
            $HELM template kps "$KPS_CHART" -f "$T/kps-values.yaml" \
                --namespace monitoring > "$T/kps-rendered.yaml"
            [ -s "$T/kps-rendered.yaml" ] || { echo "error: helm template produced empty kps-rendered.yaml" >&2; exit 1; }
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
            [ -n "$(ls "$KPS_CRDS"/* 2>/dev/null)" ] || { echo "error: no CRD files found in $KPS_CRDS" >&2; exit 1; }
            label_managed "$KPS_CRDS"/* > "$T/crds.json"
            label_all monitoring ".kind == \"List\" or .metadata.namespace == \"monitoring\"" "$T/kps-rendered.yaml" > "$T/monitoring-kps.json"
            label_all kube-system ".metadata.namespace == \"kube-system\"" "$T/kps-rendered.yaml" > "$T/kube-system-kps.json"
            label_all cluster ".kind != \"List\" and .metadata.namespace == null" "$T/kps-rendered.yaml" > "$T/cluster-kps.json"
            # kubelet SA (monitoring/) + RBAC (cluster scope) split. Both the
            # ClusterRoleBinding AND its ClusterRole come from the manifest —
            # extracting only the binding left the roleRef dangling when the
            # role lived only in the manifest (the 2026-10-05 kubelet 403).
            label_all monitoring ".kind == \"ServiceAccount\"" ${k8sDir}/manifests/kubelet-monitoring.yaml > "$T/monitoring-kubelet-sa.json"
            label_all cluster ".kind == \"ClusterRoleBinding\" or .kind == \"ClusterRole\"" ${k8sDir}/manifests/kubelet-monitoring.yaml > "$T/cluster-kubelet-crb.json"
            label_all default "true" ${appChartRenders.ai}/rendered.yaml ${k8sDir}/manifests/ai-networkpolicies.yaml > "$T/default-ai.json"
            label_all monitoring "true" ${monitoringChartRendered.loki}/rendered.yaml ${monitoringChartRendered.alloy}/rendered.yaml ${k8sDir}/manifests/cloud-model-rates.yaml ${k8sDir}/manifests/ai-model-metrics.yaml > "$T/monitoring-charts.json"
            # gpu/ pass: dcgm-exporter + its netpol + its ServiceMonitor
            # (standalone manifest, not a kps additionalServiceMonitor — the
            # chart renders those as one v1 List that cannot be split by
            # namespace, and the SM must live in gpu/ to select the pod).
            label_all gpu "true" ${monitoringChartRendered.dcgm}/rendered.yaml ${k8sDir}/manifests/dcgm-networkpolicy.yaml ${k8sDir}/manifests/dcgm-servicemonitor.yaml > "$T/gpu-charts.json"
            label_all wiki "true" ${appChartRenders.wiki}/rendered.yaml > "$T/wiki-chart.json"
            cat "$T/cluster-kps.json" "$T/cluster-kubelet-crb.json" > "$T/cluster.yaml"
            cat "$T/monitoring-kubelet-sa.json" "$T/monitoring-kps.json" "$T/monitoring-charts.json" > "$T/monitoring-static.json"
            cat "$T/kube-system-kps.json" > "$T/kube-system.yaml"
            # Last line of defense: every apply pass reads one of these
            # bundles; an empty one means the render produced nothing for
            # that scope and the prune pass would delete it.
            [ -s "$T/cluster.yaml" ] || { echo "error: rendered cluster.yaml is empty" >&2; exit 1; }
            [ -s "$T/monitoring-static.json" ] || { echo "error: rendered monitoring-static.json is empty" >&2; exit 1; }
            [ -s "$T/kube-system.yaml" ] || { echo "error: rendered kube-system.yaml is empty" >&2; exit 1; }
            [ -s "$T/default-ai.json" ] || { echo "error: rendered default-ai.json is empty" >&2; exit 1; }
            [ -s "$T/gpu-charts.json" ] || { echo "error: rendered gpu-charts.json is empty" >&2; exit 1; }
            # wiki check differs from its five siblings on purpose: a wiki failure must not fail the generation, so it skips the wiki pass and continues (siblings stay fatal — they are not wiki).
            [ -s "$T/wiki-chart.json" ] || { echo "wiki: error: rendered wiki-chart.json is empty; skipping the wiki pass" >&2; WIKI_DEPLOY=0; WIKI_SKIP_REASON="''${WIKI_SKIP_REASON:+''$WIKI_SKIP_REASON; }rendered wiki-chart.json is empty"; }
            set +e

            # CIDR containment: is $2 (net/prefix) a subnet of $1? The node's
            # podCIDR is a /24 slice of the cluster-cidr (/16), so the firewall
            # rule (scoped to the full cluster-cidr) is a safe superset — we
            # only need the node's slice to fall inside it, not equal it.
            ip_to_int() {
              local ip="$1" a b c d
              IFS=. read -r a b c d <<< "$ip"
              echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
            }
            cidr_contains() {
              local outer="$1" inner="$2"
              local outer_ip="''${outer%/*}" outer_prefix="''${outer#*/}"
              local inner_ip="''${inner%/*}" inner_prefix="''${inner#*/}"
              [ "$outer_prefix" -le "$inner_prefix" ] || return 1
              local mask=$(( (0xFFFFFFFF << (32 - outer_prefix)) & 0xFFFFFFFF ))
              [ $(( $(ip_to_int "$outer_ip") & mask )) -eq $(( $(ip_to_int "$inner_ip") & mask )) ]
            }

            WIKI_DATADIR_CHECKED=0

            # 150 x 2s = 5min: the API server can take well over 60s to be
            # ready after a fresh boot (large etcd, slow disk). A failed
            # apply persists until the next chart-changing activation, so
            # the bound is generous on purpose.
            for i in $(seq 1 150); do
              $KCTL get namespace monitoring >/dev/null 2>&1 || $KCTL create namespace monitoring
              $KCTL get namespace gpu >/dev/null 2>&1 || $KCTL create namespace gpu
              $KCTL get namespace wiki >/dev/null 2>&1 || $KCTL create namespace wiki
              # The one signal in this stack that tells a wiped wiki from a
              # fresh one: the install record present, the datadir marker absent.
              #
              # The marker is /var/lib/wiki/mysql/mysql — the system schema
              # directory mariadb:11's initdb creates, and the engine-independent
              # one (aria_log_control and ibdata1 are Aria/InnoDB artifacts). The
              # tmpfiles rule above pre-creates /var/lib/wiki/mysql at every boot,
              # so its presence says nothing; only the inner directory does. An
              # image that reorganised the datadir layout would fire this on a
              # fresh install — a false alarm, never a false silence.
              #
              # "Was installed before" means the wiki/bookstack Secret exists,
              # because every activation that deploys the wiki writes it. That
              # record is deletable: step 2 of the SECRETS.md rotation deletes
              # this Secret, and until step 3 re-activates, the read below is
              # NotFound and the check stays silent.
              #
              # Only a NotFound naming this Secret is an answer. kubectl also
              # exits non-zero for a namespace that does not exist yet (the create
              # above runs under set +e) and for a transport error; latching on
              # either would silence the check for the rest of the run.
              if [ "$WIKI_DATADIR_CHECKED" = 0 ]; then
                if WIKI_SECRET_ERR="$($KCTL get secret bookstack -n wiki 2>&1 >/dev/null)"; then
                  WIKI_DATADIR_CHECKED=1
                  if [ ! -d /var/lib/wiki/mysql/mysql ]; then
                    echo "wiki: the wiki/bookstack Secret exists but the MariaDB datadir marker /var/lib/wiki/mysql/mysql is absent — a wiki was installed here before and its database is gone; the apply continues (the loss already happened), see the \"An empty database reads as healthy\" standing note in k8s/apps/wiki/RUNBOOK.md" >&2
                  fi
                else
                  case "$WIKI_SECRET_ERR" in
                    *'Error from server (NotFound): secrets "bookstack"'*) WIKI_DATADIR_CHECKED=1 ;;
                  esac
                fi
              fi
              # Divergence check: the nftables rule for 9100/10250 is scoped
              # to $CLUSTER_CIDR (k3s' default; the nix k3s module exposes no
              # cluster-cidr option). The node's podCIDR is a /24 slice of the
              # cluster-cidr, so it must fall INSIDE $CLUSTER_CIDR (not equal
              # it). A mismatch would silently break node-exporter/kubelet
              # scrapes, so fail the apply. Empty means the node isn't
              # registered yet — keep retrying.
              NODE_CIDR=$($KCTL get node -o jsonpath='{.items[0].spec.podCIDR}' 2>/dev/null || true)
              if [ -n "$NODE_CIDR" ] && ! cidr_contains "$CLUSTER_CIDR" "$NODE_CIDR"; then
                echo "error: node podCIDR $NODE_CIDR not within cluster-cidr $CLUSTER_CIDR (firewall rule mismatch)" >&2
                exit 1
              fi
              # PSS scoping (P2-36): the DCGM exporter needs root + SYS_ADMIN
              # (CDI GPU driver), so it gets a dedicated gpu/ namespace at PSS
              # privileged. monitoring/ must also be privileged: hostPath
              # volumes are forbidden at baseline — full stop, no read-only
              # exception — and this namespace runs two hostPath DaemonSets
              # by design (alloy tails /var/log/pods; kps node-exporter reads
              # /proc,/sys,/root). The original "baseline is enough" claim was
              # never true: it only looked true because every pod in the
              # namespace was grandfathered at create time, and the first
              # DaemonSet recreation proved it — alloy bounced and could not
              # come back until the label changed. grafana/prometheus/loki
              # pods themselves need nothing more than what privileged allows
              # them, so the namespace is privileged only because its
              # DaemonSets are. label --overwrite is idempotent, so an
              # existing namespace gets the label too.
              $KCTL label namespace gpu pod-security.kubernetes.io/enforce=privileged --overwrite
              $KCTL label namespace monitoring pod-security.kubernetes.io/enforce=privileged --overwrite
              # The wiki namespace is baseline, not privileged, and that is a
              # claim about the BookStack container rather than an aspiration:
              # it starts as root (s6-overlay cannot start any other way — as
              # uid 983 it dies with "unable to setgid to root"), and it needs
              # CHOWN, DAC_OVERRIDE, FOWNER, SETGID and SETUID, all five of
              # which are on baseline's allowed add-list, with
              # allowPrivilegeEscalation: false (verified against the image,
              # including with no_new_privs). See the header of
              # k8s/apps/wiki/templates/bookstack-deployment.yaml.
              $KCTL label namespace wiki pod-security.kubernetes.io/enforce=baseline --overwrite
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
              # Secret values go to 0600 files + --from-file so they never
              # appear in kubectl's argv (visible via ps / /proc/*/cmdline
              # during activation). printf '%s' matches --from-literal's
              # exact-value semantics (no trailing newline).
              ( umask 077
                printf '%s' "$LITELLM_MASTER" > "$T/secret-master-key"
                printf '%s' "$PG_PASSWORD" > "$T/secret-pg-password"
                printf '%s' "$LITELLM_DB_URL" > "$T/secret-db-url"
                printf '%s' "$POD_API_KEY" > "$T/secret-pod-api-key"
                printf '%s' "$GRAFANA_PW" > "$T/secret-grafana-pw"
                printf '%s' "$METRICS_KEY" > "$T/secret-metrics-key"
            ${wikiSecretFiles}
              )
              $KCTL apply -f "$T/monitoring-kubelet-sa.json" \
                && $KCTL create token kubelet-monitoring --namespace monitoring \
                    --duration=87600h > "$T/kubelet-token" \
                && $KCTL create secret generic kubelet-monitoring-token \
                    --namespace monitoring \
                    --from-file=token="$T/kubelet-token" \
                    --dry-run=client -o yaml | label_all monitoring "true" > "$T/monitoring-kubelet-token.json" \
                && $KCTL create secret generic litellm-keys \
                    --namespace default \
                    --from-file=master-key="$T/secret-master-key" \
                    --from-file=postgres-password="$T/secret-pg-password" \
                    --from-file=database-url="$T/secret-db-url" \
                    --from-file=pod-api-key="$T/secret-pod-api-key" \
                    --dry-run=client -o yaml | label_all default "true" > "$T/default-litellm-keys.json" \
                && $KCTL create secret generic monitoring-secrets \
                    --namespace monitoring \
                    --from-literal=admin-user=admin \
                    --from-file=admin-password="$T/secret-grafana-pw" \
                    --dry-run=client -o yaml | label_all monitoring "true" > "$T/monitoring-secrets.json" \
                && $KCTL create secret generic llm-api-key \
                    --namespace monitoring \
                    --from-file=token="$T/secret-pod-api-key" \
                    --dry-run=client -o yaml | label_all monitoring "true" > "$T/monitoring-llm-api-key.json" \
                && $KCTL create secret generic litellm-metrics-key \
                    --namespace monitoring \
                    --from-file=token="$T/secret-metrics-key" \
                    --dry-run=client -o yaml | label_all monitoring "true" > "$T/monitoring-litellm-metrics-key.json" \
                && $KCTL create configmap mjolnir-dashboards \
                    --namespace monitoring \
                    --from-file=cluster-overview.json=${k8sDir}/apps/monitoring/dashboards/cluster-overview.json \
                    --from-file=llm-fleet.json=${k8sDir}/apps/monitoring/dashboards/llm-fleet.json \
                    --from-file=llm-overview.json=${k8sDir}/apps/monitoring/dashboards/llm-overview.json \
                    --from-file=on-demand-fleet.json=${k8sDir}/apps/monitoring/dashboards/on-demand-fleet.json \
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
                && apply_pruned "$SEL_GPU" "gpu" "$T/gpu-charts.json" \
                && apply_pruned "$SEL_KUBE_SYSTEM" "kube-system" "$T/kube-system.yaml" \
                && $KCTL label configmap mjolnir-dashboards --namespace monitoring grafana_dashboard=1 --overwrite \
                && register_metrics_key \
                && {
                      # The wiki pass runs last and it is the one apply pass
                      # whose failure does NOT abort the activation: a broken
                      # optional service must not cost the monitoring stack that
                      # sits behind it in the chain. Every wiki failure — the
                      # rotation guard below included — is loud in the journal,
                      # lets the rest of the generation land, and leaves the
                      # unit green. Nor is it retried: the realistic wiki
                      # failure is not transient — raising persistence.size
                      # (k8s/apps/wiki/templates/pvc.yaml) makes the existing
                      # claim mismatch its own immutable spec, and kubectl
                      # answers "field is immutable", which no retry fixes.
                      if [ "$WIKI_DEPLOY" = "1" ]; then
                        # DB_PASSWORD rotation guard. The cluster's own
                        # wiki/bookstack Secret is the only record of the value
                        # last applied, so the comparison is against that and not
                        # against sops. Proceed on a match, on no Secret yet (a
                        # fresh install), or on a get that itself fails: the guard
                        # is skipped then, accepted because an API server
                        # unreachable enough to fail this read fails the apply
                        # chain below too, and that reports itself.
                        #
                        # Refuse without failing the generation: exiting 1 makes
                        # deploy-rs roll the whole system generation back while
                        # the five apply passes that already landed stay in the
                        # cluster, and the two states then diverge until a human
                        # notices. WIKI_ROTATE_OK=0 gates the apply chain below.
                        # Why the password cannot be rotated by editing sops, and
                        # the one-sitting procedure that can: k8s/apps/wiki/SECRETS.md.
                        WIKI_ROTATE_OK=1
                        if APPLIED_DB_B64="$($KCTL get secret bookstack -n wiki -o jsonpath='{.data.DB_PASSWORD}' 2>/dev/null)"; then
                          APPLIED_DB_PASSWORD="$(printf '%s' "$APPLIED_DB_B64" | base64 -d 2>/dev/null)"
                          if [ -n "$APPLIED_DB_PASSWORD" ] && [ "$APPLIED_DB_PASSWORD" != "$WIKI_DB_PASSWORD" ]; then
                            WIKI_ROTATE_OK=0
                            echo "wiki: rotation refused — the wiki pass is skipped; the unit stays green" >&2
                            echo "error: wiki db-password rotation refused: services/wiki/db-password no longer matches the DB_PASSWORD last applied to the wiki/bookstack Secret, and this stack cannot rotate it. The MariaDB image sets the bookstack account's password only while the data directory is empty, so applying the new value would update the Secret and BookStack's environment while the database account keeps the old password; the mismatch would surface as Access denied at the next BookStack start. The Secret is NOT updated and the wiki stays at its previous, consistent state." >&2
                            echo "error: to change the password anyway (in one sitting — BookStack's live connections break at step 1): (1) k3s kubectl exec -it -n wiki deploy/wiki-mariadb -- mariadb -u bookstack -p  (old password at the prompt, so it stays out of any argv), then SET PASSWORD = '<the new password>';  (2) k3s kubectl delete secret bookstack -n wiki  — that Secret is this guard's memory of the last applied value;  (3) re-activate, which recreates the Secret from sops;  (4) k3s kubectl rollout restart deploy/wiki-bookstack -n wiki. Reasoning and the full version of these steps: k8s/apps/wiki/SECRETS.md." >&2
                          fi
                        fi
                        # traefik terminates TLS at the LAN Ingress, so the
                        # certificate must be for the host being served: host
                        # and Secret name are read out of the render rather than
                        # repeated here, so values.yaml stays the only place
                        # they are written. Self-signed and regenerated every
                        # pass — that keeps the Secret inside this pass's prune
                        # scope, so it is never orphaned; cert-manager and a
                        # real certificate belong to the canonical-URLs phase.
                        # head -1 means only the first Ingress gets a
                        # certificate: a second one's tls secretName would be
                        # pruned like any Secret the apply does not carry.
                        : > "$T/wiki-tls.json"
                        # From the printf'd 0600 files, never the sops paths:
                        # OIDC_CLIENT_SECRET must byte-match the value
                        # registered in Pocket ID, newline for newline.
                        #
                        # The whole pass is one guard: core/v1/Secret is in
                        # PRUNE_ALLOWLIST and both Secrets carry the wiki
                        # selector, so an apply whose Secret document is missing
                        # would prune the live Secrets while the activation
                        # exits 0 — and the rotation guard above would lose its
                        # record of the last applied value. Under set +e a bare
                        # assignment discards yq's status, and a render whose
                        # shape yq cannot read would answer "no Ingress"; hence
                        # the extractions are spliced into the chain and an empty
                        # or half-populated document is a failure in its own
                        # right.
                        #
                        # A transient openssl failure therefore applies nothing in
                        # this pass, with no red unit and no retry — the pass sits
                        # in the && chain that ends in exit 0, so the retry loop is
                        # short-circuited — and the wiki stays where it was until
                        # the next activation.
                        # The refusal gate wraps the whole pass: `if <false>; then
                        # ...; fi` yields status 0, so a refusal leaves the enclosing
                        # && chain unbroken and the unit still exits 0.
                        if [ "$WIKI_ROTATE_OK" = "1" ]; then
                          if ! {
                            WIKI_TLS_HOST="$($YQ -r 'select(.kind == "Ingress") | .spec.tls[0].hosts[0] // empty' "$T/wiki-chart.json" | head -1)" \
                            && WIKI_TLS_SECRET="$($YQ -r 'select(.kind == "Ingress") | .spec.tls[0].secretName // empty' "$T/wiki-chart.json" | head -1)" \
                            && {
                               # The disabled-Ingress path has to end in status
                               # 0 (the echo): this if is spliced into the &&
                               # chain, so a false test here fails the pass.
                               if [ -n "$WIKI_TLS_HOST" ] && [ -n "$WIKI_TLS_SECRET" ]; then
                                 $OPENSSL req -x509 -newkey rsa:2048 -nodes \
                                     -keyout "$T/wiki-tls.key" \
                                     -out "$T/wiki-tls.crt" \
                                     -days 3650 \
                                     -subj "/CN=$WIKI_TLS_HOST" \
                                     -addext "subjectAltName=DNS:$WIKI_TLS_HOST" \
                                   && $KCTL create secret tls "$WIKI_TLS_SECRET" \
                                       --namespace wiki \
                                       --cert="$T/wiki-tls.crt" \
                                       --key="$T/wiki-tls.key" \
                                       --dry-run=client -o yaml | label_all wiki "true" > "$T/wiki-tls.json" \
                                   && nonempty "$T/wiki-tls.json" "create secret tls"
                               else
                                 [ -z "$WIKI_TLS_HOST" ] && [ -z "$WIKI_TLS_SECRET" ] && \
                                   echo "note: ingress disabled — the wiki-tls Secret is outside this apply and will be pruned"
                               fi
                             } \
                            && $KCTL create secret generic bookstack \
                                --namespace wiki${wikiSecretFromArgs} \
                                --dry-run=client -o yaml | label_all wiki "true" > "$T/wiki-secret.json" \
                            && nonempty "$T/wiki-secret.json" "create secret generic" \
                            && cat "$T/wiki-secret.json" "$T/wiki-tls.json" "$T/wiki-chart.json" > "$T/wiki.yaml" \
                            && apply_pruned "$SEL_WIKI" "wiki" "$T/wiki.yaml"
                          }; then
                            echo "wiki: error: wiki apply pass failed (see output above); the wiki stays at its previous state and the rest of the activation continues" >&2
                          fi
                        fi
                      else
                        if [ -n "$WIKI_SKIP_REASON" ]; then
                          echo "wiki: $WIKI_SKIP_REASON" >&2
                        else
                          echo "wiki: wiki pass skipped (no reason recorded)" >&2
                        fi
                      fi
                    } \
                && { if [ "$CRDS_NEW" -eq 1 ]; then
                    $KCTL rollout restart deploy/kps-kube-prometheus-stack-operator --namespace monitoring
                  fi
                  exit 0
                }
              sleep 2
            done
            echo "error: chart apply failed after 5min" >&2
            exit 1
          '';
        };

        # 6443: k3s API server. 9100: node-exporter, 10250: kubelet — both
        # are hostNetwork on the node and scraped by Prometheus from the pod
        # network, so the INPUT chain must let the pod CIDR reach them.
        # allowedTCPPorts has no source restriction, so 9100/10250 get an
        # explicit nftables rule scoped to the pod CIDR (clusterCidr above;
        # the activation script fails the apply if the running cluster
        # diverges from it) instead.
        networking.firewall.allowedTCPPorts = [ 6443 ];
        # extraInputRules is appended to the input-allow chain (nftables
        # backend; extraCommands is iptables-only and asserts here).
        networking.firewall.extraInputRules = ''
          tcp dport { 9100, 10250 } ip saddr ${clusterCidr} accept
        '';
        # NOTE: the LiteLLM gateway's hostPort 8000 is NOT covered by the
        # firewall above — hostPort traffic is DNAT'd via PREROUTING to the
        # pod CNI interface and never traverses the INPUT chain that
        # networking.firewall controls. The pods themselves are ClusterIP-only
        # and authenticate with the LLAMA_API_KEY env var (from the
        # litellm-keys Secret).
      };
    };
}
