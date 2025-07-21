{ config
, pkgs
, lib
, ...
}:
{
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

  system.stateVersion = "22.11";

  systemd.services.nixos-upgrade.preStart = ''
    cd /etc/nixos
    chown -R root:root .
    git pull || true
  '';
  system.autoUpgrade = {
    enable = true;
    flake = "/etc/nixos#${config.networking.hostName}";
    flags = [
      "-L"
    ];
    dates = "Sat *-*-* 02:30:00";
    allowReboot = true;
  };

  imports = [
    ./filesystems
    ./nix
  ];

  time.timeZone = "America/New_York";

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

  programs.git.enable = true;
  programs.mosh.enable = true;
  programs.htop.enable = true;
  programs.neovim = {
    enable = true;
    viAlias = true;
    vimAlias = true;
    defaultEditor = true;
  };

  security = {
    doas.enable = lib.mkDefault false;
    sudo = {
      enable = lib.mkDefault true;
      wheelNeedsPassword = lib.mkDefault false;
    };
  };

  environment.systemPackages = with pkgs; [
    wget
    iperf3
    eza
    fastfetch
    tmux
    rsync
    iotop
    ncdu
    nmap
    jq
    ripgrep
    lm_sensors
  ];
}
