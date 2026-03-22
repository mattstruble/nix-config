{ ... }:
{
  flake.modules.nixos.packages =
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
}
