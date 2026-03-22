{ ... }:
{
  flake.modules.homeManager.shell = {
    programs.nix-index = {
      enable = true;
      enableZshIntegration = true;
    };
    programs.home-manager.enable = true;
    systemd.user.startServices = "sd-switch";
  };
}
