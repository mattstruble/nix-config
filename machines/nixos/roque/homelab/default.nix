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
      accelerationDevices = null; # 'null' give access to all devices
      openFirewall = true;
      mediaLocation = "/mnt/immich";
    };
  };

  users.groups.immich.gid = builtins.readFile config.sops.secrets."users/immich/gid".path;

  users.users.immich = {
    uid = builtins.readFile config.sops.secrets."users/immich/uid".path;
    extraGroups = [
      "video"
      "render"
    ];
  };

}
