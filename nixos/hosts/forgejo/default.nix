# NixOS system for the Incus instance "forgejo".
#
# Forgejo 16.0.5, its own PostgreSQL 18, its own LFS store, on the git forge
# project. This file replaced the empty shell that existed only to prove the
# deploy path; see ../incus.nix for the Incus half (volumes, devices, limits) and
# for which secrets the host renders in from its own sops store.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.forgejo;

  # Nothing is written to incus-secrets for this instance. incus/apply.sh writes
  # every secret into the paths the Forgejo module already declares under its own
  # customDir, because that directory is the only one its secret-bootstrap unit
  # is allowed to write; see the Secrets section below.

  # Forgejo's own user, which the module creates. Extended rather than replaced
  # so the module keeps ownership of the account definition.
  forgejoUser = {
    extraGroups = [ "git" ];
  };
in
{
  networking.hostName = "forgejo";

  # The host firewall gates this instance; see incus.nix.
  networking.firewall.enable = false;
  networking.nameservers = [ "192.168.178.1" ];

  # Nothing forwards 22 into this container yet. Git-over-SSH is served by the
  # *host's* sshd, which hands every session to `incus exec forgejo --user
  # git --`; see the host side of that in the git user's sshd config. Starting a
  # second sshd here would be unreachable surface.
  services.openssh.enable = false;

  environment.systemPackages = with pkgs; [
    curl
    git
    jq
  ];

  # --------------------------------------------------------------------------
  # PostgreSQL
  # --------------------------------------------------------------------------
  services.postgresql = {
    enable = true;

    # 18, not the module default. Two independent reasons converge here and both
    # are silent if you take the default:
    #
    #   1. The hourly dump that is going to be restored into this database is
    #      made by `pg_dump` from postgres:18-alpine (apps/forgejo/
    #      dump-cronjob.yaml). pg_restore refuses an archive written by a newer
    #      pg_dump than itself, so a 17.11 server would reject the restore with
    #      "unsupported version ... in the dump file" -- at restore time, with a
    #      database already created and nothing to roll back to.
    #   2. The k3s deployment's CNPG cluster defaulted to PostgreSQL 18, so the
    #      data being restored is 18-shaped.
    #
    # The module picks postgresql_17 for stateVersion >= 25.11, which is what
    # the flake pins, so this line is doing real work.
    package = pkgs.postgresql_18; # 18.6

    # Stated rather than inherited. `local all all peer` in the default pg_hba is
    # what makes the socket connection above work, and the socket's location is
    # PostgreSQL's compiled-in default otherwise -- one upstream change away from
    # silently not being where Forgejo is told to look.
    settings.unix_socket_directories = "/run/postgresql";
  };

  # --------------------------------------------------------------------------
  # Accounts
  # --------------------------------------------------------------------------
  # Two accounts, deliberately. `forgejo` runs the service and owns the config;
  # `git` is the identity a push arrives as and owns the repository volume. They
  # share the repositories directory through group `git` -- see the ownership
  # unit below.
  users.groups.git = { };

  users.users.git = {
    isNormalUser = true;
    description = "Git transport identity for Forgejo pushes";
    # Not a login shell and not a home directory: this account exists to own
    # files and to be the target of `incus exec --user git --`. A home under
    # /var/lib/forgejo would put a dotfile tree inside the data volume.
    home = "/var/lib/forgejo";
    createHome = false;
    group = "git";
    shell = pkgs.bashInteractive;
  };

  users.users.forgejo = forgejoUser;

  # The repositories volume arrives owned by root, because Incus created the
  # btrfs subvolume. Setgid so repositories Forgejo creates inherit group `git`,
  # which is what lets a push from the `git` identity land in a repository the
  # `forgejo` identity made.
  #
  # Idempotent, and safe to re-run: `install -d` on an existing directory keeps
  # whatever is inside it.
  systemd.services.forgejo-repositories-owner = {
    description = "Hand the repositories volume to the git group, setgid";
    wantedBy = [ "multi-user.target" ];
    before = [
      "forgejo.service"
      "postgresql.service"
    ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe' pkgs.coreutils "install" + " -d -m 2775 -o git -g git /var/lib/forgejo/data/git";
    };
  };

  # --------------------------------------------------------------------------
  # Secrets
  # --------------------------------------------------------------------------
  # All five are the *k3s deployment's* values, rendered in by the host from its
  # own sops store (see incus.nix). Nothing here is generated, and that is the
  # point -- see below.
  #
  # SECRET_KEY is the one that constrains the design. From Forgejo's own
  # configuration cheat sheet:
  #
  #   SECRET_KEY: Global secret key. This key is VERY IMPORTANT; if you lose it,
  #   data encrypted by it (like 2FA secrets) can no longer be decrypted.
  #
  # So minting a fresh one -- which is what services.forgejo does by default, via
  # its forgejo-secrets unit -- would leave any two-factor secrets in the
  # database we are about to restore permanently undecryptable. The user would be
  # silently locked out of their own account, with nothing in the logs to say
  # why. The module's default is the wrong default here and has to be overridden
  # by supplying the old value.
  #
  # The other four are less severe but still worth keeping: INTERNAL_TOKEN and
  # JWT_SECRET sign the API and Actions tokens clients already hold, and
  # LFS_JWT_SECRET signs the short-lived bearer tokens the LFS server hands out.
  # Regenerating them would invalidate every one of those at the instant of
  # cutover.
  #
  # Only the mailer password is declared here. The other four are left at the
  # module's own defaults -- ${customDir}/conf/{secret_key,internal_token,
  # oauth2_jwt_secret,lfs_jwt_secret} -- and incus.nix writes them exactly there.
  # That is deliberate rather than convenient:
  #
  #   * The module's forgejo-secrets unit generates any of them that is EMPTY,
  #     and it is sandboxed with ReadWritePaths = [customDir]. Point the four at
  #     paths outside customDir and on the very first boot -- before apply.sh has
  #     rendered anything -- that unit would try to create them there, be denied
  #     by its own sandbox, and fail. forgejo.service Requires it, so Forgejo
  #     would never start.
  #   * Writing them where the module already looks makes the generator a no-op
  #     (the files are non-empty), and needs no mkForce to redirect defaults that
  #     are already correct.
  #
  # Consequence worth knowing: because the files live in customDir, they are
  # inside the state directory rather than on a volume. customDir lives on the
  # container's root disk, which is the `persistent` pool, so they are still not
  # restic'd -- consistent with every other secret here.
  #
  # The single setting that follows from all of this is further down, inside
  # services.forgejo: only the mailer password, which has no module default.

  # --------------------------------------------------------------------------
  # Forgejo
  # --------------------------------------------------------------------------
  services.forgejo = {
    enable = true;

    # 16.0.5, explicitly. The module's default is `pkgs.forgejo-lts`, which in
    # this nixpkgs is 15.0.9 -- and a Forgejo older than the data cannot be used,
    # because its schema migrations only run forwards. The k3s deployment is on
    # 16.x (apps/forgejo/helm-release.yaml pins image tag 16) and the dump being
    # restored came out of it. Taking the default here would produce an instance
    # that builds, boots, and then cannot read its own database.
    package = pkgs.forgejo; # 16.0.5

    # app.ini is written from the settings below rather than by the install
    # wizard, so nothing ever prompts.
    useWizard = false;

    database = {
      type = "postgres";
      # The socket, not 127.0.0.1. See the pg_haba comment above: this is what
      # makes the connection passwordless.
      host = "/run/postgresql";
      name = "forgejo";
      user = "forgejo";
      # createDatabase is left at its default of true, which makes the module
      # declare ensureDatabases/ensureUsers itself -- including
      # ensureDBOwnership, so the role owns the database. Declaring them by hand
      # as well would only add a second, duplicate definition.
    };

    # Where the `repositories` volume is mounted (see incus.nix). The module's
    # default is ${stateDir}/repositories, which is a path that does not exist
    # here, so this line is load-bearing rather than documentation: without it
    # Forgejo would create and use a second repository tree on the container's
    # root disk, and every push would appear to vanish on the next rebuild.
    repositoryRoot = "/var/lib/forgejo/data/git";

    # LFS content directory defaults to ${stateDir}/data/lfs, which is exactly
    # where the `lfs` volume is mounted, so only the switch is needed.
    lfs.enable = true;

    settings = {
      DEFAULT = {
        APP_NAME = "HomeLab";
        RUN_USER = "forgejo";
        RUN_MODE = "prod";
        WORK_PATH = cfg.stateDir;
      };

      server = {
        DOMAIN = "forgejo.sakul-flee.de";

        # TLS terminates at Caddy, so Forgejo speaks plain HTTP to it. ROOT_URL
        # still has to be the https URL, or every generated link, webhook and
        # email would point at http:// and mixed content would be blocked.
        ROOT_URL = "https://forgejo.sakul-flee.de/";
        PROTOCOL = "http";
        HTTP_PORT = 3000;

        # Caddy connects from the host over the bridge, so the address it hands
        # on the Host header has to be accepted.
        USE_PROXY_PROTOCOL = false;
        REVERSE_PROXY_TRUSTED_PROXIES = "10.0.0.0/8 172.16.0.0/12";

        LFS_START_SERVER = true;

        # Git-over-SSH is advertised but NOT served by Forgejo. The host's sshd
        # answers on port 22 and forwards every session into this container as
        # the `git` user, so Forgejo never needs a listener of its own -- and
        # running one would bind a second sshd on a port nothing forwards to.
        START_SSH_SERVER = false;
        DISABLE_SSH = false;

        # Port 22 is the host's sshd, and it forwards to the `git` user here, so
        # the clone URL Forgejo advertises must be the port-22 one and must name
        # `git`. Setting SSH_PORT makes Forgejo omit the port from ssh:// URLs
        # instead of printing the k3s NodePort that is being retired.
        SSH_DOMAIN = "forgejo.sakul-flee.de";
        SSH_PORT = 22;

        # SSH_USER, not BUILTIN_SSH_SERVER_USER. It defaults to
        # %(BUILTIN_SSH_SERVER_USER)s, which is %(RUN_USER)s, i.e. `forgejo` --
        # so without this the advertised clone URL would be
        # ssh://forgejo@forgejo.sakul-flee.de/... while every push actually
        # arrives as `git`. The upstream docs are explicit that SSH_USER is the
        # knob for exactly this case: "in most cases, you want to leave this
        # blank and modify BUILTIN_SSH_SERVER_USER" -- and we are the ones
        # serving SSH, outside Forgejo.
        SSH_USER = "git";

        # Forgejo does not write authorized_keys for the transport identity --
        # the host asks the API via AuthorizedKeysCommand and rewrites the
        # command to run inside this container -- so it should not try. The docs
        # say to turn this off for that setup; leaving it on would have Forgejo
        # maintaining a file nothing reads.
        SSH_CREATE_AUTHORIZED_KEYS_FILE = false;
      };

      service = {
        # Unchanged from the k3s deployment: registration is open, and new users
        # confirm their address. A closed instance would make the first-user
        # problem impossible to get past by hand.
        DISABLE_REGISTRATION = false;
        REGISTER_EMAIL_CONFIRM = true;
        ENABLE_NOTIFY_MAIL = true;
        ENABLE_PUSH_CREATE_USER = true;
        ENABLE_PUSH_CREATE_ORG = true;
      };

      admin = {
        DEFAULT_EMAIL_NOTIFICATIONS = "enabled";
        SEND_NOTIFICATION_EMAIL_ON_NEW_USER = true;
        DISABLE_REGULAR_ORG_CREATION = true;
      };

      repository = {
        MAX_CREATION_LIMIT = 0;
      };

      security = {
        INSTALL_LOCK = true;
      };

      mailer = {
        ENABLED = true;
        PROTOCOL = "smtps";
        SMTP_ADDR = "smtp.purelymail.com";
        SMTP_PORT = 465;
        USER = "lweber@sakul-flee.de";
        FROM = "forgejo@sakul-flee.de";
      };
    };

    # Only the mailer password. See the Secrets section above for why the other
    # four are left at the module's own defaults rather than pointed elsewhere.
    secrets.mailer.PASSWD = "${cfg.customDir}/conf/smtp_password";
  };

  # GPG commit signing is NOT configured yet, and that is a deliberate gap rather
  # than an oversight. The k3s deployment had signing enabled, so commits made
  # after the cutover would show as unverified until this is added. It needs a
  # gnupg home directory on the `persistent` pool plus an import of the armored
  # private key, which is a separate change with its own failure modes -- and it
  # has nothing to do with proving the restore worked. Flagged so it is a
  # decision rather than a surprise.
}