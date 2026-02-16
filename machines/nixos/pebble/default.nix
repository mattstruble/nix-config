{ ... }:
{
  imports = [
    ../_common
    ../_rpi
  ];

  networking.hostName = "pebble";
}
