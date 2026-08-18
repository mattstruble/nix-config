{ ... }:
{
  flake.modules.nixos.vllm =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.vllm;

      args = lib.concatStringsSep " " (
        [
          "serve"
          cfg.model
          "--host"
          cfg.host
          "--port"
          (toString cfg.port)
          "--tensor-parallel-size"
          (toString cfg.tensorParallelSize)
          "--kv-cache-dtype"
          cfg.kvCacheDtype
          "--max-model-len"
          (toString cfg.maxModelLen)
          "--gpu-memory-utilization"
          (toString cfg.gpuMemoryUtilization)
        ]
        ++ cfg.extraArgs
      );

      hfCache = "/var/lib/vllm/hf-cache";
    in
    {
      options.services.vllm = {
        enable = lib.mkEnableOption "vLLM inference server";

        model = lib.mkOption {
          type = lib.types.str;
          description = "Hugging Face model repo to serve";
        };

        tensorParallelSize = lib.mkOption {
          type = lib.types.int;
          default = 1;
          description = "Number of GPUs to shard the model across";
        };

        kvCacheDtype = lib.mkOption {
          type = lib.types.str;
          default = "auto";
          description = "KV cache dtype (e.g. auto, bfloat16, fp8)";
        };

        maxModelLen = lib.mkOption {
          type = lib.types.int;
          default = 32768;
          description = "Maximum sequence length in tokens";
        };

        gpuMemoryUtilization = lib.mkOption {
          type = lib.types.number;
          default = 0.90;
          description = "Fraction of GPU memory to use for model and KV cache";
        };

        host = lib.mkOption {
          type = lib.types.str;
          default = "0.0.0.0";
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 8000;
        };

        extraArgs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
      };

      config = lib.mkIf cfg.enable {
        systemd.services.vllm-preload-model = {
          description = "Preload vLLM model to HF cache";
          wantedBy = [ "multi-user.target" ];
          before = [ "vllm.service" ];
          path = [ pkgs.python3Packages.huggingface-hub ];
          serviceConfig = {
            Type = "oneshot";
            User = "vllm";
            Group = "vllm";
            StateDirectory = "vllm";
            ExecStart = "${pkgs.python3Packages.huggingface-hub}/bin/hf download ${cfg.model}";
          };
          environment = {
            HF_HOME = hfCache;
            HF_HUB_ENABLE_HF_TRANSFER = "1";
          };
        };

        systemd.services.vllm = {
          description = "vLLM inference server";
          wantedBy = [ "multi-user.target" ];
          after = [
            "network-online.target"
            "vllm-preload-model.service"
          ];
          requires = [ "vllm-preload-model.service" ];
          wants = [ "network-online.target" ];
          path = [ pkgs.vllm ];
          serviceConfig = {
            User = "vllm";
            Group = "vllm";
            StateDirectory = "vllm";
            Restart = "on-failure";
            RestartSec = "5";
            ExecStart = "${pkgs.vllm}/bin/vllm ${args}";
          };
          environment = {
            HF_HOME = hfCache;
          };
        };

        users.users.vllm = {
          isSystemUser = true;
          group = "vllm";
        };
        users.groups.vllm = { };

        networking.firewall.allowedTCPPorts = [ cfg.port ];
      };
    };
}
