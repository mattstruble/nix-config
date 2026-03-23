{ ... }:
{
  flake.modules.darwin.llama-server =
    { config, lib, pkgs, ... }:
    let
      cfg = config.services.llama-server;

      args = lib.concatStringsSep " " (
        [
          "--hf-repo"
          cfg.hfRepo
          "--hf-file"
          cfg.hfFile
          "--port"
          (toString cfg.port)
          "-c"
          (toString cfg.contextSize)
          "-b"
          (toString cfg.batchSize)
          "-ub"
          (toString cfg.uBatchSize)
          "-ngl"
          (toString cfg.gpuLayers)
          "--cache-reuse"
          (toString cfg.cacheReuse)
          "-fa"
          "auto"
        ]
        ++ cfg.extraArgs
      );
    in
    {
      options.services.llama-server = {
        enable = lib.mkEnableOption "llama-server FIM service";

        hfRepo = lib.mkOption {
          type = lib.types.str;
          description = "Hugging Face repo to download the model from";
        };

        hfFile = lib.mkOption {
          type = lib.types.str;
          description = "GGUF filename within the HF repo";
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 8012;
        };

        contextSize = lib.mkOption {
          type = lib.types.int;
          default = 32768;
        };

        batchSize = lib.mkOption {
          type = lib.types.int;
          default = 1024;
        };

        uBatchSize = lib.mkOption {
          type = lib.types.int;
          default = 512;
        };

        gpuLayers = lib.mkOption {
          type = lib.types.int;
          default = 99;
        };

        cacheReuse = lib.mkOption {
          type = lib.types.int;
          default = 256;
        };

        extraArgs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
      };

      config = lib.mkIf cfg.enable {
        launchd.user.agents.llama-server = {
          command = "${pkgs.llama-cpp}/bin/llama-server ${args}";
          serviceConfig = {
            KeepAlive = true;
            RunAtLoad = true;
            StandardOutPath = "/tmp/llama-server.log";
            StandardErrorPath = "/tmp/llama-server.log";
          };
        };
      };
    };
}
