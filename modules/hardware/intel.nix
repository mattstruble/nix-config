{ ... }:
{
  flake.modules.nixos.intel-hardware =
    { pkgs, ... }:
    {
      nixpkgs.config.packageOverrides = prev: {
        vaapiIntel = prev.vaapiIntel.override { enableHybridCodec = true; };
      };

      hardware = {
        enableRedistributableFirmware = true;
        cpu.intel.updateMicrocode = true;
        graphics = {
          enable = true;
          extraPackages = with pkgs; [
            intel-media-driver
            intel-vaapi-driver
            libva-vdpau-driver
            intel-compute-runtime
            vpl-gpu-rt
          ];
        };
      };
    };
}
