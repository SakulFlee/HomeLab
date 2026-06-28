{ config, pkgs, lib, ... }: {
  services.forgejo.database = {
    type = "postgres";
    createDatabase = true;
    user = "forgejo";
    passwordFile = config.sops.secrets."database_password".path;
  };

  services.postgresql = {
    enable = true;
    settings = {
      logging_collector = true;
      log_directory = "log";
    };
  };
}
