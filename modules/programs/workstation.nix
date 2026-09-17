{ ... }:
{
  flake.modules.homeManager.workstation =
    { config, pkgs, ... }:
    let
      dotfiles = "${config.home.homeDirectory}/dotfiles";
      mkLink = config.lib.file.mkOutOfStoreSymlink;
    in
    {
      xdg.configFile = {
        "aerospace".source = mkLink "${dotfiles}/aerospace/.config/aerospace";
        "kitty".source = mkLink "${dotfiles}/kitty/.config/kitty";
        "harper-ls".source = mkLink "${dotfiles}/harper-ls/.config/harper-ls";
        "python_keyring".source = mkLink "${dotfiles}/keyring/.config/python_keyring";
        "sketchybar".source = mkLink "${dotfiles}/sketchybar/.config/sketchybar";
        "tmux".source = mkLink "${dotfiles}/tmux/.config/tmux";
        "wezterm".source = mkLink "${dotfiles}/wezterm/.config/wezterm";
        "yamlfmt".source = mkLink "${dotfiles}/yamlfmt/.config/yamlfmt";
      };

      fonts.fontconfig.enable = true;
    };
}
