{ config, pkgs, lib, ... }: {
  services.forgejo.database = {
    type = "postgres";
    createDatabase = true;
    user = "forgejo";
    passwordFile = config.sops.secrets."database_password".path;
    socket = "/run/postgresql";
  };

  services.postgresql = {
    enable = true;
    authentication = ''
      local forgejo forgejo peer map=forgejo-map
    '';
    identMap = ''
      forgejo-map /^(forgejo|git)$ forgejo
    '';
    settings = {
      logging_collector = true;
      log_directory = "log";
    };
  };
}
