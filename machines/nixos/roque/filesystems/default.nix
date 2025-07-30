{ config
, pkgs
, ...
}:
let
  nfsServer = config.sops.secrets."network/yggdrasil/ip".path;
  nfsShare = "/volume2/media";
  mountPoint = "/mnt/media";
in
{
  fileSystems."${mountPoint}" = {
    device = "${nfsServer}:${nfsShare}";
    fsType = "nfs";
  };

}
