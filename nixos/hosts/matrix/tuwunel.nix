{ config, pkgs, ... }: {
  sops.defaultSopsFile = ../../secrets/matrix.sops.yaml;
  sops.secrets."registration_token" = {
    mode = "0444";
  };

  services.matrix-tuwunel = {
    enable = true;
    settings.global = {
      server_name = "sakul-flee.de";
      address = [ "10.0.0.117" ];
      port = [ 6167 ];
      allow_federation = true;
      allow_registration = true;
      registration_token_file = config.sops.secrets.registration_token.path;
    };
  };

  networking.firewall.allowedTCPPorts = [ 6167 ];
}
