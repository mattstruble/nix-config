{ ... }:
{
  flake.modules.homeManager.shell =
    { config, pkgs, lib, ... }:
    let
      isDarwin = pkgs.stdenv.isDarwin;
      brew_path = "/opt/homebrew/bin";
    in
    {
      programs.nix-index = {
        enable = true;
        enableZshIntegration = true;
      };

      programs.home-manager.enable = true;

      programs.fzf = {
        enable = true;
        enableZshIntegration = true;
        defaultOptions = [
          "--height 40%"
          "--layout=reverse"
          "--info=inline"
          "--border"
          "--exact"
        ];
      };

      programs.zoxide = {
        enable = true;
        enableZshIntegration = true;
        enableBashIntegration = true;
        options = [ "--cmd cd" ];
      };

      programs.bash = lib.mkIf isDarwin {
        enable = true;
        bashrcExtra = lib.mkBefore ''
          source /etc/bashrc

          export PATH="$HOME/.pyenv:$PATH"
          export PYENV_VIRTUALENV_DISABLE_PROMPT=1

          eval "$(pyenv init --path)"
          eval "$(pyenv init -)"
          eval "$(pyenv virtualenv-init -)"
        '';
      };

      programs.zsh = {
        dotDir = "${config.xdg.configHome}/zsh";
        enable = true;
        enableCompletion = false;

        autosuggestion.enable = true;
        syntaxHighlighting.enable = true;

        history = {
          size = 50000;
          save = 500000;
          path = "${config.xdg.configHome}/zsh/history";
          ignoreDups = true;
          share = true;
          extended = true;
          ignoreSpace = true;
        };

        sessionVariables = {
          EDITOR = "nvim";
          VISUAL = "nvim";
          ALTERNATE_EDITOR = "${pkgs.vim}/bin/vi";
          LC_CTYPE = "en_US.UTF-8";
          LEDGER_COLOR = "true";
          LESS = "-FRSXM";
          LESSCHARSET = "utf-8";
          PAGER = "less";
          TINC_USE_NIX = "yes";
          WORDCHARS = "";
        } // lib.optionalAttrs isDarwin {
          SSH_AUTH_SOCK = "~/Library/Group\\ Containers/2BUA8C4S2C.com.1password/t/agent.sock";
        };

        shellAliases = {
          vi = "nvim";
          vim = "nvim";
          v = "vim_opener";
          ls = "${pkgs.coreutils}/bin/ls -h --color=auto";
          sl = "ls";
          grep = "grep --color=auto";
          back = "cd $OLDPWD";
          reload = "exec $SHELL -l";
          tkill = "tmux kill-server";
          git = "${pkgs.git}/bin/git";
          good = "${pkgs.git}/bin/git bisect good";
          bad = "${pkgs.git}/bin/git bisect bad";
        };

        profileExtra = ''
          export GPG_TTY=$(tty)
          if ! pgrep -x "gpg-agent" > /dev/null; then
              ${pkgs.gnupg}/bin/gpgconf --launch gpg-agent
          fi

          export PATH=/run/current-system/sw/bin:$HOME/.nix-profile/bin:$PATH
          if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
              . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
          fi

          [ -d "$HOME/bin" ] && PATH="$HOME/bin:$PATH"
          [ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH"
        '' + lib.optionalString isDarwin ''

          if type brew &>/dev/null; then
            FPATH=$(brew --prefix)/share/zsh-completions:$FPATH
          fi

          if [ -d "$PYENV_ROOT/bin" ]; then
            export PATH="$PYENV_ROOT/bin:$PATH"
          fi
          if command -v pyenv >/dev/null 2>&1; then
            eval "$(pyenv init --path)"
          fi

          if [ $(command -v fortune) ] && [ $UID != '0' ] && [[ $- == *i* ]] && [ $TERM != 'dumb' ]; then
              if [ $(command -v cowsay) ]; then
                  fortune -a fortunes wisdom | cowsay
              else
                  fortune -a fortunes wisdom
              fi
          fi
        '';

        initContent = lib.mkMerge [
          (lib.mkBefore ''
            # Enable Powerlevel10k instant prompt.
            if [[ -r "''${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-''${(%):-%n}.zsh" ]]; then
              source "''${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-''${(%):-%n}.zsh"
            fi
          '')
          ''
            autoload -Uz compinit && compinit

            bindkey -v
            bindkey '^f' autosuggest-accept
            bindkey '^p' history-search-backward
            bindkey '^n' history-search-forward
            bindkey '^[w' kill-region

            bindkey '^[[A' history-substring-search-up
            bindkey '^[[B' history-substring-search-down
            HISTORY_SUBSTRING_SEARCH_ENSURE_UNIQUE=1

            function zvm_after_init() {
              bindkey '^f' autosuggest-accept
              bindkey '^p' history-search-backward
              bindkey '^n' history-search-forward
              bindkey '^[w' kill-region
              bindkey '^[[A' history-substring-search-up
              bindkey '^[[B' history-substring-search-down
            }

            zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
            zstyle ':completion:*' menu no
            zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls --color $realpath'
            zstyle ':fzf-tab:complete:__zoxide_z:*' fzf-preview 'ls --color $realpath'
            zstyle ':completion:*:*:docker:*' option-stacking yes
            zstyle ':completion:*:*:docker-*:*' option-stacking yes

            [[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
          ''
          (lib.mkIf isDarwin ''
            eval "$(${brew_path}/brew shellenv)"
          '')
        ];

        plugins = [
          {
            name = "vi-mode";
            src = pkgs.zsh-vi-mode;
            file = "share/zsh-vi-mode/zsh-vi-mode.plugin.zsh";
          }
        ];

        antidote = {
          enable = true;
          plugins = [
            "getantidote/use-omz"
            "ohmyzsh/ohmyzsh path:plugins/1password"
            "ohmyzsh/ohmyzsh path:plugins/aws"
            "ohmyzsh/ohmyzsh path:plugins/brew"
            "ohmyzsh/ohmyzsh path:plugins/command-not-found"
            "ohmyzsh/ohmyzsh path:plugins/direnv"
            "ohmyzsh/ohmyzsh path:plugins/git"
            "ohmyzsh/ohmyzsh path:plugins/fzf"
            "ohmyzsh/ohmyzsh path:plugins/helm"
            "ohmyzsh/ohmyzsh path:plugins/kubectl"
            "ohmyzsh/ohmyzsh path:plugins/kubectx"
            "ohmyzsh/ohmyzsh path:plugins/podman"
            "ohmyzsh/ohmyzsh path:plugins/pyenv"
            "ohmyzsh/ohmyzsh path:plugins/python"
            "ohmyzsh/ohmyzsh path:plugins/rust"
            "ohmyzsh/ohmyzsh path:plugins/safe-paste"
            "ohmyzsh/ohmyzsh path:plugins/sudo"
            "ohmyzsh/ohmyzsh path:plugins/tmux"
            "ohmyzsh/ohmyzsh path:plugins/virtualenv"
            "ohmyzsh/ohmyzsh path:plugins/z"
            "ohmyzsh/ohmyzsh path:plugins/zoxide"
            "zsh-users/zsh-completions path:src kind:fpath"
            "zsh-users/zsh-autosuggestions"
            "zsh-users/zsh-history-substring-search"
            "Aloxaf/fzf-tab"
            "romkatv/powerlevel10k"
          ];
        };
      };

      home.sessionVariables = {
        FONTCONFIG_FILE = "${config.xdg.configHome}/fontconfig/fonts.conf";
        FONTCONFIG_PATH = "${config.xdg.configHome}/fontconfig";
        GNUPGHOME = "${config.xdg.configHome}/gnupg";
        JAVA_OPTS = "-Xverify:none";
        LESSHISTFILE = "${config.xdg.cacheHome}/less/history";
        VAGRANT_HOME = "${config.xdg.dataHome}/vagrant";
        TZ = "America/New_York";
        EDITOR = "nvim";
        XDG_CONFIG_HOME = "${config.xdg.configHome}";
        VAGRANT_DEFAULT_PROVIDER = "vmware_desktop";
        VAGRANT_VMWARE_CLONE_DIRECTORY = "${config.home.homeDirectory}/Machines/vagrant";
        FILTER_BRANCH_SQUELCH_WARNING = "1";
        PYENV_ROOT = "${config.home.homeDirectory}/.pyenv";
        PYENV_VIRTUALENV_DISABLE_PROMPT = "1";
        MANPATH = lib.concatStringsSep ":" [
          "${config.home.homeDirectory}/.nix-profile/share/man"
          "/run/current-system/sw/share/man"
          "/usr/local/share/man"
          "/usr/share/man"
        ];
      };

      home.sessionPath = lib.optionals isDarwin [
        "/usr/local/bin"
        "/usr/local/zfs/bin"
        "${brew_path}"
      ];

      home.file =
        let
          mkLink = config.lib.file.mkOutOfStoreSymlink;
          dotfiles = "${config.home.homeDirectory}/dotfiles";
        in
        {
          ".direnvrc".source = mkLink "${dotfiles}/direnv/.direnvrc";
          ".p10k.zsh".source = mkLink "${dotfiles}/p10k/.p10k.zsh";
          ".vimrc".source = mkLink "${dotfiles}/vim/.vimrc";
          ".zprofile".source = mkLink "${dotfiles}/zsh/.zprofile";
          ".subzsh".source = mkLink "${dotfiles}/zsh/subzsh";
          ".local/bin/vim_opener".source = mkLink "${dotfiles}/commands/.local/bin/vim_opener";
          ".local/bin/um".source = mkLink "${dotfiles}/commands/.local/bin/um";
        };

      systemd.user.startServices = lib.mkIf (!isDarwin) "sd-switch";

      news.display = lib.mkIf isDarwin "silent";
      home.enableNixpkgsReleaseCheck = lib.mkIf isDarwin false;

      targets.darwin = lib.mkIf isDarwin {
        defaults = {
          "com.apple.desktopservices" = {
            DSDontWriteNetworkStores = true;
            DSDontWriteUSBStores = true;
          };
        };
      };
    };
}
