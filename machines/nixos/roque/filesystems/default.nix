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
  fileSystems."${mountPoint}" = {
    device = "${nfsServer}:${nfsShare}";
    fsType = "nfs";
  };

}
