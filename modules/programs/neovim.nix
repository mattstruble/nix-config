{ ... }:
{
  flake.modules.homeManager.neovim =
    { config, ... }:
    let
      dotfiles = "${config.home.homeDirectory}/dotfiles";
      mkLink = config.lib.file.mkOutOfStoreSymlink;
    in
    {
      programs.neovim = {
        enable = true;
        viAlias = true;
        vimAlias = true;
        defaultEditor = true;
      };

      xdg.configFile."nvim".source = mkLink "${dotfiles}/nvim/.config/nvim";
    };
}
