{ config
, pkgs
, lib
, ...
}:
{
  system.stateVersion = "25.05";

  boot.tmp.useTmpfs = true;
  boot.tmp.cleanOnBoot = true;
  time.timeZone = "America/New_York";
  systemd.services.nix-daemon.environment.TMPDIR = "/var/tmp";

  systemd.services.nixos-upgrade.preStart = ''
    cd /etc/nixos
    chown -R root:root .
    git pull || true
  '';
  system.autoUpgrade = {
    enable = true;
    flake = "/etc/nixos#${config.networking.hostName}";
    flags = [ "-L" ];
    dates = "Sat *-*-* 02:30:00";
    allowReboot = true;
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  nix.optimise.automatic = true;
  nix.optimise.dates = [ "weekly" ];

  nix.settings.experimental-features = lib.mkDefault [
    "nix-command"
    "flakes"
  ];

  nixpkgs = {
    config = {
      allowUnfree = true;
      allowUnfreePredicate = (_: true);
    };
  };

  security = {
    doas.enable = lib.mkDefault false;
    sudo = {
      enable = lib.mkDefault true;
      wheelNeedsPassword = lib.mkDefault false;
    };
  };
}
