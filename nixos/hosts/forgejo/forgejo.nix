{ config, pkgs, lib, ... }:
let
  domain = "forgejo.sakul-flee.de";
in {
  sops.defaultSopsFile = ../../secrets/forgejo.sops.yaml;

  sops.secrets = {
    "database_password" = { };
    "jwt_secret" = { };
    "lfs_secret" = { };
    "internal_token" = { };
    "smtp_password" = { };
  };

  services.forgejo = {
    enable = true;
    user = "forgejo";
    group = "forgejo";
    stateDir = "/var/lib/forgejo";

    lfs.enable = true;

    secrets = {
      security.INTERNAL_TOKEN = lib.mkForce config.sops.secrets."internal_token".path;
      oauth2.JWT_SECRET = lib.mkForce config.sops.secrets."jwt_secret".path;
      server.LFS_JWT_SECRET = lib.mkForce config.sops.secrets."lfs_secret".path;
    };

    # SSH is handled by the system OpenSSH daemon (START_SSH_SERVER = false)
    # AuthorizedKeysCommand is configured via services.openssh below

    settings = {
      DEFAULT = {
        APP_NAME = "Forgejo: Beyond coding. We forge.";
        RUN_MODE = "prod";
      };

      service = {
        REGISTER_EMAIL_CONFIRM = true;
        ENABLE_PUSH_CREATE_USER = true;
        ENABLE_PUSH_CREATE_ORG = true;
        DISABLE_REGISTRATION = false;
        ENABLE_NOTIFY_MAIL = true;
      };

      metrics.ENABLED = false;

      session.PROVIDER = "memory";

      server = {
        START_SSH_SERVER = false;
        SSH_PORT = 22;
        SSH_USER = "forgejo";
        SSH_DOMAIN = domain;
        PROTOCOL = "http";
        HTTP_PORT = 3000;
        DOMAIN = domain;
        ROOT_URL = "https://${domain}";
        LFS_START_SERVER = true;
        ENABLE_PPROF = false;
      };

      mailer = {
        ENABLED = true;
        USER = "dev@sakul-flee.de";
        PASSWD_FILE = config.sops.secrets."smtp_password".path;
        PROTOCOL = "smtps";
        SMTP_ADDR = "smtp.purelymail.com";
        SMTP_PORT = 465;
        FROM = "forgejo@sakul-flee.de";
      };

      queue.TYPE = "level";

      cache.ADAPTER = "memory";

      security = {
        INSTALL_LOCK = true;
      };

      repository.MAX_CREATION_LIMIT = 0;

      admin = {
        SEND_NOTIFICATION_EMAIL_ON_NEW_USER = true;
        DISABLE_REGULAR_ORG_CREATION = true;
        DEFAULT_EMAIL_NOTIFICATIONS = "enabled";
      };

    };
  };

  services.openssh.extraConfig = ''
    Match User forgejo
        AuthorizedKeysCommand ${pkgs.forgejo-lts}/bin/forgejo keys -c ${config.services.forgejo.customDir}/conf/app.ini -e git -u %u -t %t -k %k
        AuthorizedKeysCommandUser forgejo
        AllowTcpForwarding no
        X11Forwarding no
  '';

  networking.firewall.allowedTCPPorts = [ 3000 22 ];

  systemd.services.forgejo = {
    after = [ "sops-install-secrets.service" ];
    requires = [ "sops-install-secrets.service" ];
  };
}
