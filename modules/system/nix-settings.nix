{ inputs, ... }:
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

      nixpkgs = {
        config = {
          allowUnfree = true;
          allowUnfreePredicate = (_: true);
        };
      };
    };

  flake.modules.darwin.nix-settings =
    { lib, ... }:
    {
      nix = {
        enable = false;

        settings = {
          allow-dirty = true;
          allowed-users = [ "*" ];
          build-users-group = "nixbld";
          builders-use-substitutes = true;
          eval-cache = true;
          experimental-features = lib.mkDefault [
            "nix-command"
            "flakes"
          ];
          extra-nix-path = "nixpkgs=flake:nixpkgs";
          flake-registry = "https://github.com/NixOS/flake-registry/raw/master/flake-registry.json";
          http-connections = 25;
          http2 = true;
          impersonate-linux-26 = false;
          keep-going = true;
          max-jobs = "auto";
          substitute = true;
          substituters = [ "https://cache.nixos.org/" ];
          trusted-substituters = [ "https://cache.flakehub.com" ];
          trusted-public-keys = [
            "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
            "cache.flakehub.com-3:hJuILl5sVK4iKm86JzgdXW12Y2Hwd5G07qKtHTOcDCM= cache.flakehub.com-4:Asi8qIv291s0aYLyH6IOnr5Kf6+OF14WVjkE6t3xMio= cache.flakehub.com-5:zB96CRlL7tiPtzA9/WKyPkp3A2vqxqgdgyTVNGShPDU= cache.flakehub.com-6:W4EGFwAGgBj3he7c5fNh9NkOXw0PUVaxygCVKeuvaqU= cache.flakehub.com-7:mvxJ2DZVHn/kRxlIaxYNMuDG1OvMckZu32um1TadOR8= cache.flakehub.com-8:moO+OVS0mnTjBTcOUh2kYLQEd59ExzyoW1QgQ8XAARQ= cache.flakehub.com-9:wChaSeTI6TeCuV/Sg2513ZIM9i0qJaYsF+lZCXg0J6o= cache.flakehub.com-10:2GqeNlIp6AKp4EF2MVbE1kBOp9iBSyo0UPR9KoR0o1Y="
          ];
          trusted-users = [ "@admin" "@wheel" ];
          use-case-hack = false;
          use-registries = true;
          use-sqlite-wal = true;
        };

        registry = lib.mapAttrs (_: value: { flake = value; }) inputs;
        distributedBuilds = false;

        extraOptions = ''
          gc-keep-derivations = true
          gc-keep-outputs = true
        '';
      };

      nixpkgs = {
        config = {
          allowUnfree = true;
          allowBroken = false;
          allowInsecure = false;
          allowUnsupportedSystem = false;
        };
      };
    };
}
