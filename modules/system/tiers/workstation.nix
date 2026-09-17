{ inputs, ... }:
{
  flake.modules.darwin.tier-workstation =
    { pkgs, ... }:
    {
    imports = with inputs.self.modules.darwin; [
      home-manager-integration
      nix-settings
      security
      macos-defaults
      homebrew
      user-mestruble
    ];

    home-manager.sharedModules = with inputs.self.modules.homeManager; [
      shell
      neovim
      git
      dev-tools
      browser
      ai-agents
      workstation
      cli-tools
      ssh-client
    ];

    fonts.packages = with pkgs; [ iosevka ];
  };
}
