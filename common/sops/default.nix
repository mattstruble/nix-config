{ ... }:
{
  sops = {
    defaultSopsFile = ./secrets.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    age.keyFile = "/var/lib/sops-nix/key.txt";
    age.generateKey = true;
    secrets = {
      "users/mestruble/password" = {
        neededForUsers = true;
      };
      "users/root/password" = {
        neededForUsers = true;
      };
      "network/yggdrasil/ip" = { };
    };
  };
}
