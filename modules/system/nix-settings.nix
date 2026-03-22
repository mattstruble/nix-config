{ ... }:
{
  flake.modules.nixos.nix-settings =
    { config, lib, ... }:
    {
      boot.tmp.useTmpfs = true;
      time.timeZone = "America/New_York";
      systemd.services.nix-daemon.environment.TMPDIR = "/var/tmp";

      systemd.services.nixos-upgrade.preStart = ''
        cd /etc/nixos
        chown -R root:root .
        git pull
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

      system.stateVersion = "25.05";

      nixpkgs = {
        config = {
          allowUnfree = true;
          allowUnfreePredicate = (_: true);
        };
      };
    };
}
