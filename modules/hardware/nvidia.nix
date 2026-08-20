{ lib, ... }:
{
  flake.modules.nixos.nvidia-hardware =
    { pkgs, config, ... }:
    {
      options.hardware.nvidia = {
        cudaCapabilities = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "7.5" ];
          description = "CUDA compute capabilities to build CUDA-dependent packages for (e.g. Turing sm_75)";
        };
      };

      config = {
        nixpkgs.config = {
          cudaSupport = lib.mkDefault true;
          cudaCapabilities = config.hardware.nvidia.cudaCapabilities;
        };

        hardware.enableRedistributableFirmware = true;

        hardware.graphics = {
          enable = true;
          extraPackages = with pkgs; [
            nvidia-vaapi-driver
          ];
        };

        hardware.nvidia = {
          modesetting.enable = true;
          open = false;
          nvidiaSettings = false;
        };

        services.xserver.videoDrivers = [ "nvidia" ];

        boot.initrd.kernelModules = [ "nvidia" ];
        boot.extraModulePackages = [ config.boot.kernelPackages.nvidia_x11 ];
      };
    };
}
