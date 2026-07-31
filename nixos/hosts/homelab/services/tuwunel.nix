{ config, ... }: {
  sops.secrets."tuwunel_registration_token" = {
    mode = "0444";
  };

  services.matrix-tuwunel = {
    enable = true;
    settings = {
      global = {
        server_name = "sakul-flee.de";
        address = [ "127.0.0.1" ];
        port = [ 6167 ];
        allow_federation = true;
        allow_registration = true;
        registration_token_file = config.sops.secrets.tuwunel_registration_token.path;
      };
      media.retention = [
        {
          scope = "remote";
          accessed = "30d";
        }
        {
          scope = "thumbnail";
          accessed = "14d";
        }
      ];
    };
  };

  services.homelab-restic = {
    enable = true;
    paths = [ "/var/lib/private/tuwunel" ];
  };
}
