{ config
, pkgs
, lib
, modulesPath
, ...
}:
{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
  ];

  sdImage = {
    compressImage = false;
    imageName = "${config.networking.hostName}.img";
  };
}
