{ ... }:
{
  flake.modules.nixos.llama-fleet =
    { config, lib, ... }:
    let
      cfg = config.llama;

      # The server always listens on this port inside the container; the host
      # port is per-model, so two models can never collide on a host port only
      # if their `port` options differ (see the assertion below for GPUs).
      containerPort = 8080;

      enabledModels = lib.filterAttrs (_: m: m.enable) cfg.models;

      # Two models on one 24GB card OOMs; two models publishing the same host
      # port fails at docker start. Both are eval-time failures naming culprits.
      noDuplicates = getter: label: show: {
        assertion =
          (lib.length (lib.attrNames enabledModels))
          == (lib.length (lib.unique (map getter (lib.attrValues enabledModels))));
        message =
          "llama.models: two enabled models claim the same ${label}: "
          + (lib.concatStringsSep ", " (lib.mapAttrsToList (n: m: "${n} -> ${show m}") enabledModels));
      };
    in
    {
      options.llama.models = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              enable = lib.mkEnableOption "this llama.cpp model";

              # No default on purpose: reading them unset throws with the exact
              # option path, so an enabled model can never silently land on the
              # wrong GPU or port.
              gpu = lib.mkOption {
                type = lib.types.int;
                description = "NVIDIA GPU index (CDI device nvidia.com/gpu=<gpu>).";
              };

              port = lib.mkOption {
                type = lib.types.port;
                description = "Host port the server is reachable on.";
              };

              image = lib.mkOption {
                type = lib.types.str;
                description = "Container image, digest-pinned.";
              };

              package = lib.mkOption {
                type = lib.types.nullOr lib.types.package;
                default = null;
                description = "llama.cpp build to run from the nix store instead of the image entrypoint.";
              };

              model = lib.mkOption {
                type = lib.types.str;
                description = "Main GGUF path as seen inside the container.";
              };

              args = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Raw llama-server flags, verbatim (--alias, MTP, KV cache, sampling...).";
              };

              volumes = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ "/var/lib/llama-models:/models" ];
                description = "Container volumes.";
              };

              environment = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                default = {
                  GGML_CUDA_DISABLE_GRAPHS = "1";
                };
                description = "Container environment.";
              };
            };
          }
        );
        default = { };
        description = "llama.cpp models to serve. Definitions live in the host's _llama-models.nix; the host switchboard sets enable + gpu.";
      };

      config = lib.mkIf (enabledModels != { }) {
        virtualisation.oci-containers.containers = lib.mapAttrs' (
          name: m:
          lib.nameValuePair "llama-${name}" {
            image = m.image;
            cmd =
              (lib.optionals (m.package != null) [ "${m.package}/bin/llama-server" ])
              ++ [
                "-m"
                m.model
              ]
              ++ m.args
              ++ [
                "--host"
                "0.0.0.0"
                "--port"
                (toString containerPort)
                "--api-key"
                "foo"
              ];
            # A store-built binary needs the store mounted; its rpath resolves
            # every nix dependency, the image only provides CUDA userland.
            volumes = m.volumes ++ lib.optionals (m.package != null) [ "/nix/store:/nix/store:ro" ];
            environment = m.environment;
            ports = [ "${toString m.port}:${toString containerPort}" ];
            extraOptions = [
              "--device"
              "nvidia.com/gpu=${toString m.gpu}"
              "--shm-size"
              "32g"
              "--ipc=host"
            ];
          }
        ) enabledModels;

        networking.firewall.allowedTCPPorts = map (m: m.port) (lib.attrValues enabledModels);

        assertions = [
          (noDuplicates (m: m.gpu) "GPU" (m: "gpu ${toString m.gpu}"))
          (noDuplicates (m: m.port) "host port" (m: "port ${toString m.port}"))
        ];
      };
    };
}
