{ inputs, ... }:
{
  flake.modules.darwin.MacStruble = {
    imports = with inputs.self.modules.darwin; [
      tier-workstation
      llama-server
    ];

    networking.hostName = "MacStruble";
    system.stateVersion = 4;

    services.llama-server = {
      enable = true;
      hfRepo = "ggerganov/Qwen2.5-Coder-1.5B-Q8_0-GGUF";
      hfFile = "qwen2.5-coder-1.5b-q8_0.gguf";
    };

    home-manager.users.mestruble = {
      programs.ai-agents.opencode.config = {
        model = "anthropic/claude-sonnet-4-5-20250929";
        provider = {
          ollama = {
            npm = "@ai-sdk/openai-compatible";
            name = "Ollama (local)";
            options.baseURL = "http://localhost:11434/v1";
            models = {
              "qwen2.5-coder:14b" = {
                name = "Qwen 2.5 Coder 14B";
                limit = { context = 32768; output = 8192; };
              };
              "qwen2.5:7b" = {
                name = "Qwen 2.5 7B";
                limit = { context = 32768; output = 8192; };
              };
            };
          };
        };
        agent = {
          orchestrator.model = "anthropic/claude-sonnet-4-5-20250929";
          coder.model = "anthropic/claude-sonnet-4-5-20250929";
          pr-reviewer.model = "ollama/qwen2.5-coder:14b";
          security.model = "anthropic/claude-sonnet-4-5-20250929";
          fetcher.model = "ollama/qwen2.5:7b";
        };
      };

      programs.git.settings.user = {
        name = "Matt Struble";
        email = "4325029+mattstruble@users.noreply.github.com";
      };
      programs.git.settings.github.user = "mattstruble";

      # Host-specific CA bundle (system certs instead of nix cacert)
      home.sessionVariables = {
        AWS_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
        REQUESTS_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
        NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/ca-certificates.crt";
        SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
        CURL_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
        PIP_CERT = "/etc/ssl/certs/ca-certificates.crt";
      };

      home.file = {
        ".curlrc".text = ''
          capath=/etc/ssl/certs
          cacert=/etc/ssl/certs/ca-certificates.crt
        '';
        ".wgetrc".text = ''
          ca_directory = /etc/ssl/certs
          ca_certificate = /etc/ssl/certs/ca-certificates.crt
        '';
      };

      programs.git.settings.http = {
        sslCAinfo = "/etc/ssl/certs/ca-certificates.crt";
        sslverify = true;
      };

      home.packages = with inputs.nixpkgs.legacyPackages.aarch64-darwin; [
        (lib.lowPrio gdtoolkit_4)
        opentofu
      ];
    };
  };
}
