{ ... }:
{
  flake.modules.homeManager.dev-tools =
    { config, pkgs, lib, ... }:
    let
      isDarwin = pkgs.stdenv.isDarwin;
      ca-bundle_path = "${pkgs.cacert}/etc/ssl/certs";
      ca-bundle_crt = "${ca-bundle_path}/ca-bundle.crt";
    in
    {
      programs.direnv = {
        enable = true;
        enableBashIntegration = true;
        enableZshIntegration = true;
        nix-direnv.enable = true;
      };

      programs.gpg = {
        enable = true;
        homedir = "${config.xdg.configHome}/gnupg";
      };

      programs.htop.enable = true;
      programs.info.enable = true;
      programs.jq.enable = true;
      programs.man.enable = true;
      programs.vim.enable = true;

      home.sessionVariables = lib.mapAttrs (_: lib.mkDefault) {
        AWS_CA_BUNDLE = ca-bundle_crt;
        REQUESTS_CA_BUNDLE = ca-bundle_crt;
        NODE_EXTRA_CA_CERTS = ca-bundle_crt;
        SSL_CERT_FILE = ca-bundle_crt;
        CURL_CA_BUNDLE = ca-bundle_crt;
        PIP_CERT = ca-bundle_crt;
      };

      home.file =
        let
          mkLink = config.lib.file.mkOutOfStoreSymlink;
          dotfiles = "${config.home.homeDirectory}/dotfiles";
        in
        {
          ".curlrc".text = lib.mkDefault ''
            capath=${ca-bundle_path}
            cacert=${ca-bundle_crt}
          '';
          ".wgetrc".text = lib.mkDefault ''
            ca_directory = ${ca-bundle_path}
            ca_certificate = ${ca-bundle_crt}
          '';
        };

      xdg.configFile = {
        "gnupg/gpg-agent.conf".text = lib.mkIf isDarwin ''
          enable-ssh-support
          default-cache-ttl 86400
          max-cache-ttl 86400
          pinentry-program ${pkgs.pinentry_mac}/Applications/pinentry-mac.app/Contents/MacOS/pinentry-mac
        '';

        "aspell/config".text = ''
          local-data-dir ${pkgs.aspell}/lib/aspell
          data-dir ${pkgs.aspellDicts.en}/lib/aspell
          personal ${config.xdg.configHome}/aspell/en_US.personal
          repl ${config.xdg.configHome}/aspell/en_US.repl
        '';
      };

      home.activation.setupDockerCliPlugins = lib.mkIf isDarwin (
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          DOCKER_CONFIG="$HOME/.docker"
          DOCKER_CLI_PLUGINS="$DOCKER_CONFIG/cli-plugins"
          DOCKER_CONFIG_JSON="$DOCKER_CONFIG/config.json"
          BREW_PLUGINS="/opt/homebrew/lib/docker/cli-plugins"

          if [ -d "$DOCKER_CLI_PLUGINS" ]; then
            find "$DOCKER_CLI_PLUGINS" -maxdepth 1 -type l ! -exec test -e {} \; -delete
          fi

          if [ -f "$DOCKER_CONFIG_JSON" ]; then
            EXISTING=$(${pkgs.jq}/bin/jq -r '.cliPluginsExtraDirs // [] | join(",")' "$DOCKER_CONFIG_JSON" 2>/dev/null || echo "")
            if ! echo "$EXISTING" | grep -q "$BREW_PLUGINS"; then
              ${pkgs.jq}/bin/jq --arg dir "$BREW_PLUGINS" '.cliPluginsExtraDirs = ((.cliPluginsExtraDirs // []) + [$dir] | unique)' \
                "$DOCKER_CONFIG_JSON" > "$DOCKER_CONFIG_JSON.tmp" && mv "$DOCKER_CONFIG_JSON.tmp" "$DOCKER_CONFIG_JSON"
            fi
          else
            mkdir -p "$DOCKER_CONFIG"
            echo '{"cliPluginsExtraDirs": ["'"$BREW_PLUGINS"'"]}' | ${pkgs.jq}/bin/jq . > "$DOCKER_CONFIG_JSON"
          fi
        ''
      );
    };
}
