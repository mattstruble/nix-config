{ config
, pkgs
, lib
, ...
}:
{
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
}
