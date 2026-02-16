{ ... }:
let
  home = {
    username = "mestruble";
    homeDirectory = "/home/mestruble";
    stateVersion = "23.11";
  };
in
{
  home = home;
  programs.nix-index = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.neovim = {
    enable = true;
    viAlias = true;
    vimAlias = true;
    defaultEditor = true;
  };

  programs.home-manager.enable = true;

  systemd.user.startServices = "sd-switch";
}
