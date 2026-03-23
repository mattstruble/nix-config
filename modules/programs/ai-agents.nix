{ inputs, ... }:
{
  flake.modules.homeManager.ai-agents =
    { config, ... }:
    let
      dotfiles = "${config.home.homeDirectory}/dotfiles";
      mkLink = config.lib.file.mkOutOfStoreSymlink;
    in
    {
      imports = [ inputs.ai-agents.homeManagerModules.default ];

      programs.ai-agents = {
        enable = true;
        agents = [ "opencode" ];
        subagents = [ "${dotfiles}/opencode/.config/opencode/agents/" ];
        skills = [
          {
            source = inputs.skills-mattpocock;
            include = [
              "grill-me"
              "improve-codebase-architecture"
              "prd-to-issue"
              "prd-to-plan"
              "write-a-prd"
            ];
          }
          inputs.skills-mattstruble
        ];

        mcpServers = {
          context7 = {
            type = "remote";
            url = "https://mcp.context7.com/mcp";
          };
        };

        opencode = {
          agentsFile = mkLink "${dotfiles}/opencode/.config/opencode/AGENTS.md";
          config = {
            "$schema" = "https://opencode.ai/config.json";
            agent = {
              orchestrator.tools."github*" = true;
              fetcher.tools."context7*" = false;
            };
            permission = {
              external_directory = {
                "/tmp/opencode-wt/**" = "allow";
                "/private/tmp/opencode-wt/**" = "allow";
                "~/.opencode/**" = "allow";
              };
              bash = {
                "*" = "ask";
                "cat *" = "allow"; "cd /tmp/opencode-wt/*" = "allow";
                "cd /private/tmp/opencode-wt/*" = "allow";
                "file *" = "allow"; "head *" = "allow"; "ls *" = "allow";
                "echo *" = "allow"; "sort *" = "allow"; "md5sum *" = "allow";
                "sha256sum *" = "allow"; "stat *" = "allow"; "tail *" = "allow";
                "wc *" = "allow"; "mkdir ~/.opencode/*" = "allow";
                "mkdir -p ~/.opencode/*" = "allow";
                "find *" = "allow"; "grep *" = "allow"; "rg *" = "allow"; "which *" = "allow";
                "git *" = "allow"; "git worktree *" = "allow";
                "git add *" = "ask"; "git checkout *" = "ask"; "git cherry-pick *" = "ask";
                "git clean *" = "ask"; "git commit *" = "ask"; "git merge *" = "ask";
                "git mv *" = "ask"; "git pull *" = "ask"; "git push *" = "ask";
                "git rebase *" = "ask"; "git reset *" = "ask"; "git restore *" = "ask";
                "git revert *" = "ask"; "git rm *" = "ask"; "git stash *" = "ask";
                "git switch *" = "ask"; "git tag *" = "ask";
                "pip list *" = "allow"; "pip show *" = "allow";
                "python --version" = "allow"; "python3 --version" = "allow";
                "uv --version" = "allow"; "uv pip list *" = "allow"; "uv pip show *" = "allow";
                "uv tree *" = "allow"; "uv python list *" = "allow"; "uv version *" = "allow";
                "uv run pytest *" = "allow"; "uv run coverage *" = "allow";
                "uv run ruff *" = "allow"; "uv run mypy *" = "allow";
                "uv run pyright *" = "allow"; "uv run bandit *" = "allow";
                "uv run pre-commit *" = "allow";
                "nix eval *" = "allow"; "nix flake metadata *" = "allow";
                "nix flake show *" = "allow"; "nix-store --query *" = "allow";
                "nix-store -q *" = "allow";
                "docker images *" = "allow"; "docker info" = "allow";
                "docker inspect *" = "allow"; "docker logs *" = "allow";
                "docker ps *" = "allow"; "docker version" = "allow";
                "cargo check *" = "allow"; "go vet *" = "allow";
                "make --dry-run *" = "allow"; "make -n *" = "allow";
              };
              edit = "allow"; glob = "allow"; grep = "allow"; list = "allow";
              task = "allow"; skill = "allow"; lsp = "allow"; read = "allow";
              webfetch = "allow";
            };
          };
        };
      };

      xdg.configFile = {
        "opencode/tui.json".source = mkLink "${dotfiles}/opencode/.config/opencode/tui.json";
        "opencode/themes".source = mkLink "${dotfiles}/opencode/.config/opencode/themes";
      };
    };
}
