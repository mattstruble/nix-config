{ inputs, ... }:
{
  flake.nixosConfigurations = inputs.self.lib.mkNixos "x86_64-linux" "roque";

  # Files prefixed with _ are excluded from import-tree auto-discovery
  flake.modules.nixos.roque =
    { pkgs, ... }:
    {
      imports =
        (with inputs.self.modules.nixos; [
          nix-settings
          security
          networking
          packages
          ssh
          sops
          users
          intel-hardware
          homelab
          autoaspm
        ])
        ++ [
          (inputs.self.lib.modulesPath + "/installer/scan/not-detected.nix")
          ./_hardware-configuration.nix
          ./_locale.nix
        ];

      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;
      boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

      networking.hostName = "roque";

      environment.systemPackages = with pkgs; [
        pciutils
        glances
        hdparm
        hd-idle
        hddtemp
        smartmontools
        cpufrequtils
        intel-gpu-tools
        powertop
        nfs-utils
        ungoogled-chromium
      ];
    };
}
