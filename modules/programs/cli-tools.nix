{ ... }:
{
  flake.modules.nixos.cli-tools =
    { pkgs, ... }:
    {
      programs.git.enable = true;
      programs.htop.enable = true;
      programs.mosh.enable = true;
      powerManagement.powertop.enable = true;

      environment.systemPackages = with pkgs; [
        eza
        fastfetch
        iotop
        iperf3
        jq
        just
        lm_sensors
        ncdu
        nmap
        ripgrep
        rsync
        tmux
        wget
      ];
    };

  flake.modules.homeManager.cli-tools =
    { pkgs, lib, ... }:
    {
      home.packages = with pkgs; [
        _1password-cli
        actionlint
        ansible-language-server
        ansible-lint
        asciidoctor
        aspell
        aspellDicts.en
        (ast-grep.overrideAttrs (old: { doCheck = false; }))
        awscli2
        bash-language-server
        bibtex2html
        cacert
        (lib.lowPrio cargo)
        chafa
        checkmake
        codespell
        cowsay
        (lib.lowPrio ctags)
        curl
        diffstat
        diffutils
        direnv
        docutils
        fd
        fennel-ls
        ffmpeg
        fnlfmt
        fortune
        fzf
        git-credential-oauth
        git-extras
        gitlint
        gitMinimal
        gnugrep
        gnumake
        gnupg
        gnuplot
        gnused
        go
        gradle
        harper
        helm-ls
        imagemagick
        iperf
        jiq
        jq
        just
        killall
        kubectl
        lazygit
        ldns
        less
        libevent
        libfido2
        libtiff
        (lib.lowPrio lua)
        luarocks
        markdownlint-cli
        markdownlint-cli2
        markdown-oxide
        mas
        mdformat
        mermaid-cli
        (lib.lowPrio neovim)
        nix-diff
        nix-index
        nix-info
        nix-prefetch-scripts
        nixd
        nixfmt
        nixpkgs-lint
        nmap
        obsidian
        opam
        opencode
        opensc
        openssh
        openssl
        pandoc
        pdfgrep
        perl
        perlPackages.ImageExifTool
        pinentry_mac
        plantuml
        protobufc
        psrecord
        pstree
        pv
        (lib.lowPrio python3)
        reattach-to-user-namespace
        rename
        renameutils
        ripgrep
        rsync
        ruff
        (lib.lowPrio rustfmt)
        rustup
        shellcheck
        shellharden
        shfmt
        sops
        sqldiff
        sqruff
        squashfsTools
        ssh-to-age
        stern
        stow
        stylua
        tectonic
        terminal-notifier
        terraform-ls
        tex-fmt
        texlab
        texlivePackages.lacheck
        tflint
        tmux
        translate-shell
        tree
        tree-sitter
        ty
        ueberzugpp
        universal-ctags
        uv
        viu
        wget
        write-good
        yaml-language-server
        yamlfmt
        yamllint
        yarn
        yubikey-agent
        yubikey-manager
        yubikey-personalization
        zfs-prune-snapshots
        zoxide
        zsh
        zsh-autosuggestions
        zsh-fzf-history-search
        zsh-powerlevel10k
        zsh-syntax-highlighting
        zsh-vi-mode
      ];
    };
}
