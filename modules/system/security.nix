{ ... }:
{
  flake.modules.nixos.security =
    { lib, ... }:
    {
      security = {
        doas.enable = lib.mkDefault false;
        sudo = {
          enable = lib.mkDefault true;
          wheelNeedsPassword = lib.mkDefault true;
          extraRules = [
            {
              users = [ "mestruble" ];
              commands = [
                { command = "ALL"; options = [ "NOPASSWD" ]; }
              ];
            }
          ];
        };
      };
    };
}
