{ config, pkgs, lib, ... }:
let
  domain = "forgejo.sakul-flee.de";
in {
  sops.secrets = {
    "forgejo_jwt_secret" = {};
    "forgejo_lfs_secret" = {};
    "forgejo_internal_token" = {};
    "forgejo_smtp_password" = {};
  };

  system.activationScripts.forgejo-wrapper = ''
    cat > /run/forgejo-wrapper.sh << 'WRAPPER'
    #!${pkgs.bash}/bin/bash
    set -e
    case "$1" in
      keys)
        shift
        exec ${pkgs.forgejo-lts}/bin/forgejo keys "$@"
        ;;
      serv)
        shift
        exec /run/wrappers/bin/sudo -u forgejo SSH_ORIGINAL_COMMAND="$SSH_ORIGINAL_COMMAND" /run/forgejo-wrapper.sh serv-inner "$@"
        ;;
      serv-inner)
        shift
        exec ${pkgs.forgejo-lts}/bin/forgejo serv "$@"
        ;;
      *)
        echo "Unknown subcommand: $1" >&2
        exit 1
        ;;
    esac
    WRAPPER
    chmod 755 /run/forgejo-wrapper.sh
  '';

  security.sudo.extraRules = [{
    users = [ "git" ];
    runAs = "forgejo";
    commands = [{
      command = "/run/forgejo-wrapper.sh";
      options = [ "NOPASSWD" "SETENV" ];
    }];
  }];

  services.openssh.settings = {
    PasswordAuthentication = lib.mkDefault false;
    PubkeyAuthentication = lib.mkDefault true;
    X11Forwarding = lib.mkForce false;
  };
  services.openssh.extraConfig = ''
      Match User git
          AuthorizedKeysCommand /run/forgejo-wrapper.sh keys -c ${config.services.forgejo.customDir}/conf/app.ini -w ${config.services.forgejo.stateDir} -e git -u %u -t %t -k %k
          AuthorizedKeysCommandUser forgejo
          AllowTcpForwarding no
          X11Forwarding no
  '';

  users.users.git = {
    isSystemUser = true;
    group = "forgejo";
    shell = pkgs.bash;
    home = "/home/git";
    createHome = true;
  };

  services.forgejo = {
    enable = true;
    user = "forgejo";
    group = "forgejo";
    stateDir = "/var/lib/forgejo";

    lfs.enable = true;

    database = {
      type = "postgres";
      user = "forgejo";
      socket = "/run/postgresql";
    };

    secrets = {
      security.INTERNAL_TOKEN = lib.mkForce config.sops.secrets."forgejo_internal_token".path;
      oauth2.JWT_SECRET = lib.mkForce config.sops.secrets."forgejo_jwt_secret".path;
      server.LFS_JWT_SECRET = lib.mkForce config.sops.secrets."forgejo_lfs_secret".path;
    };

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

      metrics.ENABLED = true;
      session.PROVIDER = "memory";
      queue.TYPE = "level";
      cache.ADAPTER = "memory";

      server = {
        START_SSH_SERVER = false;
        SSH_PORT = 22;
        SSH_USER = "git";
        SSH_DOMAIN = domain;
        PROTOCOL = "http";
        HTTP_PORT = 3002;
        DOMAIN = domain;
        ROOT_URL = "https://${domain}";
        LFS_START_SERVER = true;
        ENABLE_PPROF = false;
        SSH_CREATE_AUTHORIZED_KEYS_FILE = false;
        SSH_AUTHORIZED_KEYS_COMMAND_TEMPLATE = "/run/forgejo-wrapper.sh serv --config={{.CustomConf}} key-{{.Key.ID}}";
      };

      mailer = {
        ENABLED = true;
        USER = "dev@sakul-flee.de";
        PASSWD_FILE = config.sops.secrets."forgejo_smtp_password".path;
        PROTOCOL = "smtps";
        SMTP_ADDR = "smtp.purelymail.com";
        SMTP_PORT = 465;
        FROM = "forgejo@sakul-flee.de";
      };

      security = {
        INSTALL_LOCK = true;
      };

      webhook.ALLOWED_HOST_LIST = "10.0.0.0/24, 192.168.178.1/24, 10.100.0.1/24, woodpecker.sakul-flee.de, matrix.sakul-flee.de, teamcity.jetbrains.com";

      repository.MAX_CREATION_LIMIT = 0;

      admin = {
        SEND_NOTIFICATION_EMAIL_ON_NEW_USER = true;
        DISABLE_REGULAR_ORG_CREATION = true;
        DEFAULT_EMAIL_NOTIFICATIONS = "enabled";
      };
    };
  };

  systemd.tmpfiles.rules = [
    "d '${config.services.forgejo.customDir}/conf' 0750 forgejo forgejo - -"
  ];

  services.homelab-restic = {
    enable = true;
    paths = [ "/var/lib/forgejo" ];
  };
}
