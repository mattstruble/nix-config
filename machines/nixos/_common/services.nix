{ config
, pkgs
, lib
, ...
}:
{
  services.autoaspm.enable = true;
  programs.git.enable = true;
  programs.htop.enable = true;
  programs.mosh.enable = true;

  services.openssh = {
    enable = lib.mkDefault true;
    settings = {
      PasswordAuthentication = lib.mkDefault false;
      LoginGraceTime = 0;
      PermitRootLogin = "no";
    };
    hostKeys = [
      {
        path = "/persist/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
      {
        path = "/persist/ssh/ssh_host_rsa_key";
        type = "rsa";
        bits = 4096;
      }
    ];
  };

  powerManagement.powertop.enable = true;

  programs.ssh = {
    knownHosts = {
      "github.com".publicKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEM+saqSDNRJt5qpi6lltteSsdY7wNVz5Is2ywVFcyzv";
    };
    extraConfig = ''
      Host github.com
        User git
        IdentityFile /persist/ssh/ssh_host_ed25519_key
        IdentitiesOnly yes
    '';
  };
}
