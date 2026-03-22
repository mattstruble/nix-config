{ ... }:
{
  flake.modules.nixos.security =
    { lib, ... }:
    {
      security = {
        doas.enable = lib.mkDefault false;
        sudo = {
          enable = lib.mkDefault true;
          wheelNeedsPassword = lib.mkDefault false;
        };
      };
    };
}
