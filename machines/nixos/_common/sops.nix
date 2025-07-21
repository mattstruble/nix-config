{
  sops = {
    defaultSopsFile = ./secrets.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets = {
      "users/mestruble/password" = {
        neededForUsers = true;
      };
      "users/root/password" = {
        neededForUsers = true;
      };
    };
  };
}
