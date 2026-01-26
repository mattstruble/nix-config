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
      "services/pocket-id/env" = {
        sopsFile = ./secrets.yaml;
      };
    };
  };
}
