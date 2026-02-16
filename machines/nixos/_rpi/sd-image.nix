{ config
, pkgs
, lib
, ...
}:
{
  imports = [
    # "${pkgs.path}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
  ];

  # sdImage = {
  #   compressImage = false;
  #   imageName = "${config.networking.hostName}.img";
  # };
}
