{
  sops = {
    secrets = {
      "users/immich/gid" = {
        sopsFile = ./secrets.yaml;
      };
      "users/immich/uid" = {
        sopsFile = ./secrets.yaml;
      };
    };
  };
}
