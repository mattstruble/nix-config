{
  sops = {
    secrets = {
      "users/immich/gid" = {
        sopsFile = ./secrets.yaml;
      };
      "users/immich/uid" = {
        sopsFile = ./secrets.yaml;
      };
      "services/karakeep/env" = {
        sopsFile = ./secrets.yaml;
      };
      "services/hedgedoc/env" = {
        sopsFile = ./secrets.yaml;
      };
    };
  };
}
