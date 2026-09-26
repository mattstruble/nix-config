{ inputs, ... }:
{
  flake.modules.nixos.rpi-hardware =
    { config, lib, ... }:
    {
      imports = [
        (inputs.self.lib.modulesPath + "/installer/scan/not-detected.nix")
        (inputs.self.lib.modulesPath + "/installer/sd-card/sd-image-aarch64.nix")
      ];

      boot.initrd.availableKernelModules = [
        "xhci_pci"
        "usbhid"
      ];
      boot.initrd.kernelModules = [ ];
      boot.kernelModules = [ ];
      boot.extraModulePackages = [ ];

      fileSystems."/" = {
        device = "/dev/disk/by-label/NIXOS_SD";
        fsType = "ext4";
        options = [ "noatime" ];
      };

      swapDevices = [ ];

      networking.useDHCP = lib.mkForce true;
      nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
      hardware.enableRedistributableFirmware = true;

      boot.loader.grub.enable = false;
      boot.loader.generic-extlinux-compatible.enable = true;

      boot.kernelParams = [
        "cgroup_enable=cpuset"
        "cgroup_enable=memory"
        "cgroup_memory=1"
      ];

      sdImage = {
        compressImage = false;
        imageName = "${config.networking.hostName}.img";
      };

      networking.firewall.enable = true;
      services.timesyncd.enable = true;
    };
}
