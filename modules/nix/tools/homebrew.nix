{ ... }:
{
  flake.modules.darwin.homebrew = {
    homebrew = {
      enable = true;
      onActivation = {
        autoUpdate = true;
        upgrade = true;
      };

      taps = [
        "1password/tap"
        "FelixKratz/formulae"
        "nikitabobko/tap"
      ];

      brews = [
        "bibtexconv"
        {
          name = "borders";
          start_service = true;
          restart_service = "changed";
        }
        {
          name = "colima";
          start_service = true;
          restart_service = "changed";
        }
        "docker"
        "docker-compose"
        "docker-buildx"
        "fennel"
        "fnlfmt"
        "ical-buddy"
        "markdown-toc"
        "mas"
        {
          name = "sketchybar";
          start_service = true;
          restart_service = "changed";
        }
        "ollama"
        "pyenv-virtualenv"
        "uv"
        "zsh-completions"
      ];

      casks = [
        "1password"
        "aerospace"
        "alfred"
        "flux-app"
        "font-iosevka-nerd-font"
        "kitty"
        "love"
        "menuwhere"
        "monitorcontrol"
        "only-switch"
        "scroll-reverser"
        "zen"
      ];

      masApps = { };
    };
  };
}
