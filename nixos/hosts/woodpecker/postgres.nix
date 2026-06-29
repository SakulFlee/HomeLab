{ config, pkgs, lib, ... }: {
  services.postgresql = {
    enable = true;
    ensureDatabases = [ "woodpecker" ];
    ensureUsers = [{
      name = "woodpecker";
      ensureDBOwnership = true;
    }];
    authentication = ''
      local woodpecker woodpecker peer map=woodpecker-map
      host woodpecker woodpecker 127.0.0.1/32 trust
    '';
    identMap = ''
      woodpecker-map /^(woodpecker)$ woodpecker
    '';
    settings = {
      logging_collector = true;
      log_directory = "log";
    };
  };
}
