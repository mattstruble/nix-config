{ config
, pkgs
, ...
}:
let
  nfsServer = "10.0.0.123";
  nfsShare = "/volume2/media";
  mountPoint = "/mnt/media";
in
{
  fileSystems."/mnt/media" = {
    device = "${nfsServer}:/volume2/media";
    fsType = "nfs";
  };

  fileSystems."/mnt/immich" = {
    device = "${nfsServer}:/volume1/immich";
    fsType = "nfs";
  };

}
