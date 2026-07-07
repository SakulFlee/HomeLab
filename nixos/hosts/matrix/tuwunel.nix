{ config, pkgs, lib, ... }:
let
  asToken = "1q6BzIIfaKDcaNE9qtjTORb07leCva3rRrVhNCO_qOOuhJ05CTBkkgCDk6CCC-dl";
  hsToken = "vUAZ0cyDUtvLSBrxSapJKt2rUXnINjZM8UhXjWv8kwRZvtJQrRhJpbsQPogj_P--";

  registrationFile = pkgs.writeText "discord-registration.yaml" ''
    id: discord
    url: "http://10.0.0.118:29334"
    as_token: "${asToken}"
    hs_token: "${hsToken}"
    sender_localpart: discordbot
    rate_limited: false
    namespaces:
      users:
      - regex: "@discord_.*:sakul-flee.de"
        exclusive: true
      aliases:
      - regex: "#discord_.*:sakul-flee.de"
        exclusive: true
  '';

  tomlFormat = pkgs.formats.toml { };
  tuwunelConfig = tomlFormat.generate "tuwunel.toml" {
    global = {
      server_name = "sakul-flee.de";
      address = [ "10.0.0.117" ];
      port = [ 6167 ];
      allow_federation = true;
      allow_registration = true;
      registration_token_file = config.sops.secrets.registration_token.path;
      database_path = "/var/lib/tuwunel/";
      app_service_config_files = [ "${registrationFile}" ];
    };
  };
in {
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

  systemd.services.tuwunel.environment.TUWUNEL_CONFIG = lib.mkForce tuwunelConfig;

  networking.firewall.allowedTCPPorts = [ 6167 ];
}
