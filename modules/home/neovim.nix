{ ... }:
{
  flake.modules.homeManager.neovim = {
    programs.neovim = {
      enable = true;
      viAlias = true;
      vimAlias = true;
      defaultEditor = true;
    };
  };
}
