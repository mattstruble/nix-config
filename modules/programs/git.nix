{ ... }:
{
  flake.modules.homeManager.git =
    { config, pkgs, lib, ... }:
    let
      ca-bundle_crt = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      dotfiles = "${config.home.homeDirectory}/dotfiles";
      mkLink = config.lib.file.mkOutOfStoreSymlink;
    in
    {
      programs.gh = {
        enable = true;
        settings = {
          editor = "nvim";
          git_protocol = "ssh";
          aliases = {
            co = "pr checkout";
            pv = "pr view";
          };
        };
      };

      programs.git = {
        enable = true;
        package = pkgs.gitMinimal;

        ignores = [
          "*~"
          "*.swp"
          ".DS_Store"
          "*.null-ls*"
          ".direnv"
          ".envrc"
          "Thumbs.db"
        ];

        signing = {
          key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEM+saqSDNRJt5qpi6lltteSsdY7wNVz5Is2ywVFcyzv";
          signByDefault = true;
        };

        settings = {
          aliases = {
            amend = "commit --amend -C HEAD";
            authors =
              "!\"${pkgs.git}/bin/git log --pretty=format:%aN"
              + " | ${pkgs.coreutils}/bin/sort"
              + " | ${pkgs.coreutils}/bin/uniq -c"
              + " | ${pkgs.coreutils}/bin/sort -rn\"";
            b = "branch --color -v";
            ca = "commit --amend";
            changes = "diff --name-status -r";
            clone = "clone --bare --recursive";
            co = "checkout";
            cp = "cherry-pick";
            dc = "diff --cached";
            dh = "diff HEAD";
            ds = "diff --staged";
            from = "!${pkgs.git}/bin/git bisect start && ${pkgs.git}/bin/git bisect bad HEAD && ${pkgs.git}/bin/git bisect good";
            ls-ignored = "ls-files --exclude-standard --ignored --others";
            rc = "rebase --continue";
            rh = "reset --hard";
            ri = "rebase --interactive";
            rs = "rebase --skip";
            ru = "remote update --prune";
            snap = "!${pkgs.git}/bin/git stash" + " && ${pkgs.git}/bin/git stash apply";
            snaplog =
              "!${pkgs.git}/bin/git log refs/snapshots/refs/heads/" + "\$(${pkgs.git}/bin/git rev-parse HEAD)";
            spull =
              "!${pkgs.git}/bin/git stash" + " && ${pkgs.git}/bin/git pull" + " && ${pkgs.git}/bin/git stash pop";
            su = "submodule update --init --recursive";
            undo = "reset --soft HEAD^";
            kd = "difftool --no-symlinks --dir-diff";
            w = "status -sb";
            wdiff = "diff --color-words";
            l =
              "log --graph --pretty=format:'%Cred%h%Creset"
              + " —%Cblue%d%Creset %s %Cgreen(%cr)%Creset'"
              + " --abbrev-commit --date=relative --show-notes=*";
            untracked = "git fetch --prune && git branch -r | awk '{print \$1}' | egrep -v -f /dev/fd/0 <(git branch -vv | grep origin) | awk '{print \$1}'";
            remove-untracked = "git fetch --prune && git branch -r | awk '{print \$1}' | egrep -v -f /dev/fd/0 <(git branch -vv | grep origin) | awk '{print \$1}' | xargs git branch -d";
          };

          core = {
            editor = "nvim";
            trustctime = false;
            pager = "${pkgs.less}/bin/less --tabs=4 -RFX";
            logAllRefUpdates = true;
            precomposeunicode = false;
            whitespace = "trailing-space,space-before-tab";
          };

          branch.autosetupmerge = true;
          commit = {
            gpgsign = true;
            status = false;
          };
          gpg.format = "ssh";
          "gpg \"ssh\"".program = "/Applications/1Password.app/Contents/MacOS/op-ssh-sign";

          credential.helper = "store";
          ghi.token = "!${pkgs.pass}/bin/pass show api.github.com | head -1";
          hub.protocol = "${pkgs.openssh}/bin/ssh";
          mergetool.keepBackup = true;
          pull.rebase = true;
          rebase.autosquash = true;
          rerere.enabled = true;
          init.defaultBranch = "main";
          lfs.enable = true;

          "merge \"ours\"".driver = true;
          "magithub \"ci\"".enabled = false;

          http = {
            sslCAinfo = lib.mkDefault ca-bundle_crt;
            sslverify = true;
          };

          color = {
            status = "auto";
            diff = "auto";
            branch = "auto";
            interactive = "auto";
            ui = "auto";
            sh = "auto";
          };

          push = {
            default = "tracking";
            autoSetupRemote = true;
            recurseSubmodules = "on-demand";
          };

          merge = {
            conflictstyle = "diff3";
            stat = true;
          };

          "color \"sh\"" = {
            branch = "yellow reverse";
            workdir = "blue bold";
            dirty = "red";
            dirty-stash = "red";
            repo-state = "red";
          };

          annex = {
            backends = "BLAKE2B512E";
            alwayscommit = false;
          };

          "filter \"media\"" = {
            required = true;
            clean = "${pkgs.git}/bin/git media clean %f";
            smudge = "${pkgs.git}/bin/git media smudge %f";
          };

          submodule.recurse = true;

          diff = {
            ignoreSubmodules = "dirty";
            renames = "copies";
            mnemonicprefix = true;
            tool = "kitty";
            guitool = "kitty.gui";
          };

          difftool = {
            prompt = false;
            trustExitCode = true;
          };

          "difftool \"kitty\"".cmd = "kitten diff $LOCAL $REMOTE";
          "difftool \"kitty.gui\"".cmd = "kitten diff $LOCAL $REMOTE";

          advice = {
            statusHints = false;
            pushNonFastForward = false;
            objectNameWarning = "false";
          };

          "filter \"lfs\"" = {
            clean = "${pkgs.git-lfs}/bin/git-lfs clean -- %f";
            smudge = "${pkgs.git-lfs}/bin/git-lfs smudge --skip -- %f";
            required = true;
          };
        };
      };

      xdg.configFile."lazygit".source = mkLink "${dotfiles}/lazygit/.config/lazygit";
    };
}
