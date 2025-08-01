{ config
, inputs
, pkgs
, lib
, ...
}:
{
  services = {
    plex = {
      enable = true;
      openFirewall = true;
    };
    pulseaudio.enable = true;

    immich = {
      enable = true;
      host = "0.0.0.0";
      accelerationDevices = null; # 'null' give access to all devices
      openFirewall = true;
      mediaLocation = "/mnt/immich";
    };
  };

  users.groups.immich.gid = lib.mkForce 65541;

  users.users.immich = {
    uid = lib.mkForce 1039;

    extraGroups = [
      "video"
      "render"
    ];
  };

}
