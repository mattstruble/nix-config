{
  sops = {
    secrets = {
      "users/immich/gid" = {
        sopsFile = ./secrets.yaml;
        neededForUsers = true;
      };
      "users/immich/uid" = {
        sopsFile = ./secrets.yaml;
        neededForUsers = true;
      };
    };
  };
}
