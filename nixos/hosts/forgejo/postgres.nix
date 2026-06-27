{ config, pkgs, lib, ... }: {
  services.forgejo.database = {
    type = "postgres";
    createDatabase = true;
    user = "forgejo";
    passwordFile = config.sops.secrets."database_password".path;
  };

  services.postgresql = {
    enable = true;
    enableTCPIP = true;
    authentication = ''
      local forgejo forgejo scram-sha-256
      host  forgejo forgejo 127.0.0.1/32 scram-sha-256
    '';
    settings = {
      listen_addresses = lib.mkForce "127.0.0.1";
      logging_collector = true;
      log_directory = "log";
    };
  };
}
