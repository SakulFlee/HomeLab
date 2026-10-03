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

  # APP_DATA_PATH. Not set anywhere below, so it is the module default of
  # ${cfg.stateDir}/data -- but that path is the *mount point* of the forgejo-data
  # volume, and it is the one directory in this container that the host owns
  # outright rather than the guest creating it. So it is named here once and used
  # by name, because getting it wrong is silent in both directions: too high and
  # Forgejo writes state onto the container's root disk instead of the volume; too
  # low and it writes into a directory that does not exist.
  dataPath = "${cfg.stateDir}/data";

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

    # The `forgejo-postgres` volume is mounted here, and this line is the only
    # thing that makes that true.
    #
    # The module's default is /var/lib/postgresql/<major> -- literally
    # `/var/lib/postgresql/18` -- and it was silently winning. PGDATA therefore
    # lived on the container's root disk while the volume sat empty at
    # /var/lib/postgresql/data, and nothing complained: the database started, ran
    # its migrations, and served HTTP perfectly with 72MB of real data in the
    # wrong place. It was only found by asking the running server
    #
    #   psql -tAc 'SHOW data_directory'   ->  /var/lib/postgresql/18
    #
    # after a cleanup appeared to do nothing. Every "PostgreSQL PGDATA -- never
    # file-back-up, pg_dump only" volume description was describing a directory
    # nothing was using.
    #
    # Overriding dataDir is a supported path, not a hack: the module keys its
    # behaviour on exactly this comparison (a non-default dataDir gets
    # ReadWritePaths instead of StateDirectory), which is why the ownership unit
    # below exists -- StateDirectory is what would otherwise have created and
    # chowned it, and it does not apply here.
    #
    # Deliberately pointing the *volume* at /var/lib/postgresql/18 instead would
    # avoid the ownership unit, and would also re-introduce this exact bug the
    # next time the major version moved: the device path would still be 18 while
    # the data would be 19, and nothing would say so.
    dataDir = "/var/lib/postgresql/data";

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

    # Traverse, nothing more. Measured rather than assumed: with only the `git`
    # group, a push fails at the *first* step, not at the write --
    #
    #   stat: cannot statx '/var/lib/forgejo/data/git': Permission denied
    #
    # because /var/lib/forgejo and /var/lib/forgejo/data are 0750 forgejo:forgejo
    # and `other` has no access. Being in group forgejo grants r-x on those two,
    # which is exactly traverse and no more.
    #
    # Deliberately not enough to read anything. Group `forgejo` owns the
    # rendered secrets, so this would be enough -- except that custom/conf is
    # held at 0700 by forgejo-config-privacy below, which takes group traverse
    # away and with it any path to app.ini or the five secrets. Verified by
    # reading them as this account after that unit runs, not inferred.
    extraGroups = [ "forgejo" ];
  };

  users.users.forgejo = forgejoUser;

  # The volume root is the one directory in this container that the *host* owns,
  # and nothing in the guest creates it.
  #
  # Incus makes a custom volume a btrfs subvolume created by the daemon as root,
  # and it uses 0711 -- traverse, but no list and no write. Measured in the
  # running instance:
  #
  #   /var/lib/forgejo/data            drwx--x--x 711 root:root (0:0)
  #   /var/lib/postgresql/data         drwx------ 700 postgres:postgres
  #
  # The contrast is the whole point: the postgres volume has a unit below that
  # hands it over, and the data volume had no counterpart, so it stayed as Incus
  # made it. StateDirectory covers ${cfg.stateDir} but not the mount point below
  # it, and the module ships no tmpfiles at all (checked in the instance:
  # /usr/lib/tmpfiles.d is empty).
  #
  # Forgejo then fails at startup, after the port is already bound:
  #
  #   unable to create chunked upload directory:
  #   mkdir /var/lib/forgejo/data/tmp: permission denied
  #
  # 0711 grants traverse, so this is quieter than it should be: the `git`
  # transport walks the repositories underneath without complaint and only
  # Forgejo's own writes fail.
  systemd.services.forgejo-data-dir = {
    description = "Hand APP_DATA_PATH to forgejo -- Incus creates it 0711 root:root";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    before = [
      "forgejo-repositories-owner.service"
      "forgejo.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # 0750, matching what the `git` user's group grant is documented to rely
      # on: r-x for group forgejo is exactly traverse, which is all the
      # transport identity needs, and nothing more -- custom/conf stays 0700.
      ExecStart = lib.getExe' pkgs.coreutils "install"
        + " -d -m 0750 -o forgejo -g forgejo "
        + dataPath;
    };
  };

  # custom/conf is where app.ini and all five rendered secrets live, and the
  # module creates the directory as a StateDirectory at 0750 -- readable by group
  # `forgejo`. Which is fine right up until `git` is put in group `forgejo` for
  # the traversal below, at which point the transport identity can read them:
  #
  #   -r--r----- 1 forgejo forgejo /var/lib/forgejo/custom/conf/secret_key
  #   su git -c 'cat .../custom/conf/secret_key'   -> succeeds
  #
  # That matters because `git` is who every SSH session on the host lands as, so
  # anything it can read, anyone who can open a connection can read -- and
  # SECRET_KEY is the key whose reuse is what keeps the admin's TOTP secrets
  # decryptable. It also signs session cookies, so it is not a file to hand to a
  # network-reachable login "harmlessly".
  #
  # 0700 puts the boundary back: `forgejo` owns the directory and is the only
  # thing that ever reads those files, and the files' own 0440 becomes
  # unreachable once the directory stops granting group traverse.
  #
  # Ordered after local-fs.target because that is when systemd applies the
  # StateDirectory mode, which would otherwise put 0750 straight back.
  systemd.services.forgejo-config-privacy = {
    description = "Keep app.ini and the rendered secrets out of group forgejo's reach";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    before = [ "forgejo.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe' pkgs.coreutils "chmod" + " 0700 " + cfg.customDir + "/conf";
    };
  };

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
    after = [
      "local-fs.target"
      "forgejo-data-dir.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe' pkgs.coreutils "install" + " -d -m 2775 -o git -g git " + cfg.repositoryRoot;
    };
  };

  # Setgid alone is not enough, and this is the second half of the same problem.
  #
  # The ownership unit above makes the repositories directory 2775 git:git, so
  # new repositories inherit group `git`. But Forgejo creates them 2755 -- setgid
  # yes, group write no:
  #
  #   /var/lib/forgejo/data/git/probe-a  2755 forgejo:git
  #   touch …/probe-a/HEAD: Permission denied
  #
  # So `git-receive-pack`, arriving as `git`, can read a repository Forgejo
  # created and cannot write to it. Widening the mode is not an option: Forgejo
  # chooses 2755 itself, on every repository, and would undo it.
  #
  # A default ACL is the mechanism that survives that, because it is inherited
  # rather than applied:
  #
  #   setfacl -d -m g:git:rwx /var/lib/forgejo/data/git
  #   /var/lib/forgejo/data/git/probe-b  2775 forgejo:git   group:git:rwx
  #   touch …/probe-b/HEAD: ok
  #   git init --bare …/probe-c; touch …/probe-c/objects/info/x: ok
  #
  # All three measured in the running instance before this was written down.
  #
  # The paths in that transcript are /data/git because repositoryRoot was one
  # level too high when they were taken -- see the repositoryRoot note. The
  # units now apply the same two operations to whatever repositoryRoot is, so
  # the mechanism is unchanged; only the directory moved.
  #
  # system.posixACLs is deliberately NOT enabled. That option remounts / and
  # /var with acl, and the default ACL lives on the `repositories` volume, which
  # is a separate btrfs mount that already accepts ACLs -- verified by the setfacl
  # above succeeding with the option off.
  #
  # Idempotent: setfacl replaces the entry rather than adding to it. Ordered
  # after the ownership unit because that one creates the directory, and before
  # forgejo.service because repositories created before it exists would not
  # inherit the ACL.
  systemd.services.forgejo-repositories-acl = {
    description = "Make repositories Forgejo creates group-writable for the git transport identity";
    wantedBy = [ "multi-user.target" ];
    after = [ "forgejo-repositories-owner.service" ];
    before = [ "forgejo.service" ];
    path = [ pkgs.acl ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe' pkgs.acl "setfacl" + " -d -m g:git:rwx " + cfg.repositoryRoot;
    };
  };

  # Because dataDir above is not the module's default, StateDirectory does not
  # apply and nothing would create or chown it. Incus creates the mount point,
  # owned by root, and initdb refuses to run in a directory it does not own.
  #
  # 0700 postgres:postgres, matching what the module's tmpfiles rules would have
  # produced had StateDirectory applied. Idempotent, and `install -d` keeps
  # whatever is already inside it.
  systemd.services.forgejo-postgres-dir = {
    description = "Create and own PGDATA, which the module does not do for a non-default dataDir";
    wantedBy = [ "multi-user.target" ];
    before = [ "postgresql.service" ];
    after = [ "local-fs.target" ];
    path = [ pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe' pkgs.coreutils "install" + " -d -m 0700 -o postgres -g postgres /var/lib/postgresql/data";
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
  # Consequence worth knowing: because the files live in customDir, they are
  # inside the state directory rather than on a volume. customDir lives on the
  # container's root disk, which is the `persistent` pool, so they are still not
  # restic'd -- consistent with every other secret here.
  #
  # --------------------------------------------------------------------------
  # Why *_URI and not services.forgejo.secrets
  # --------------------------------------------------------------------------
  # services.forgejo.secrets is the obvious option and it does not work in this
  # container. It is a wrapper over systemd's LoadCredential=, and inside this
  # LXC that cannot function:
  #
  #   /run/credentials -> ../../dev/.incus-systemd-credentials
  #
  # Incus backs that path with a read-only mount so that systemd credentials can
  # be passed in from the host. systemd then cannot create
  # /run/credentials/<unit>/ inside it, the directory silently does not appear,
  # and the module's environment-to-ini step reports
  #
  #   Error reading file for FORGEJO__SECURITY__SECRET_KEY__FILE :
  #   /run/credentials/forgejo.service/… permission denied
  #
  # which is at least accurate about the cause and misleading about everything
  # else. INTERNAL_TOKEN then never reaches app.ini, Forgejo tries to generate
  # one at startup, and dies writing to a file the module's own pre-start has
  # just made read-only:
  #
  #   generateSaveInternalToken() [F] Error saving internal token: failed to
  #   save "/var/lib/forgejo/custom/conf/app.ini": permission denied
  #
  # Verified rather than inferred: a transient unit in this container with
  # -p LoadCredential=probe:/etc/hostname --uid=forgejo finds no
  # /run/credentials/<unit>/ at all, while /run/credentials itself exists and
  # systemd is 260.4.
  #
  # Forgejo's own *_URI settings sidestep it: `file:/path` makes Forgejo read
  # the file itself, with no systemd involvement. All five values have one --
  # SECRET_KEY_URI, INTERNAL_TOKEN_URI, JWT_SECRET_URI, LFS_JWT_SECRET_URI and
  # PASSWD_URI -- so nothing is lost by not using the module's option.
  #
  # What is preserved by writing them into customDir/conf: the module's
  # forgejo-secrets unit generates any of them that is EMPTY, and it is sandboxed
  # with ReadWritePaths = [customDir]. Point these anywhere else and on a first
  # boot, before apply.sh has rendered anything, that unit would try to create
  # them there, be denied by its own sandbox, and fail a unit forgejo.service
  # Requires. Where they are now, it is a no-op.
  #
  # The files are rendered 0440 root:forgejo rather than 0400 root:root, because
  # Forgejo now reads them as the `forgejo` user instead of systemd doing it as
  # root. At 0400 root:root, smtp_password -- which apply.sh created before the
  # setgid bit on customDir/conf existed -- was unreadable to Forgejo.

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

    # The volume is mounted at APP_DATA_PATH, and the k3s deployment's own layout
    # puts the repositories one level below that, under a directory of its own:
    #
    #   <data>/git/gitea-repositories/<owner>/<repo>.git
    #   <data>/git/.ssh          the transport identity's home
    #   <data>/git/.gnupg        private-keys-v1.d -- the commit-signing keys
    #
    # So repositoryRoot is <data>/git/gitea-repositories, NOT <data>/git. Getting
    # this wrong is quiet: Forgejo stores repository paths in the database
    # RELATIVE to the root (verified against the restored dump -- zero rows match
    # '/%'), so a root one level too high is not a parse error, it is Forgejo
    # looking for SakulFlee/HomeLab.git in a directory that does not exist, and
    # reporting every repository as missing while the files sit right there.
    #
    # The module's own default is ${stateDir}/repositories, which is also not
    # where they are.
    repositoryRoot = "${dataPath}/git/gitea-repositories";

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

        # See the Secrets section: services.forgejo.secrets relies on systemd
        # LoadCredential, which cannot work inside this container.
        LFS_JWT_SECRET_URI = "file:${cfg.customDir}/conf/lfs_jwt_secret";

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

        # Read from the rendered file rather than from app.ini. See the Secrets
        # section above -- services.forgejo.secrets cannot work in this
        # container, and these two are the ones that made Forgejo fatal.
        #
        # INTERNAL_TOKEN_URI matters most: without it Forgejo's
        # generateSaveInternalToken() fires, tries to write the value into
        # app.ini, and dies with "permission denied" -- because the module's
        # pre-start deliberately ends with `chmod u-w` on that file. Its own
        # docstring says the value is "<random at every install if no uri set>",
        # so the URI is the supported way to supply one.
        SECRET_KEY_URI = "file:${cfg.customDir}/conf/secret_key";
        INTERNAL_TOKEN_URI = "file:${cfg.customDir}/conf/internal_token";
      };

      oauth2 = {
        JWT_SECRET_URI = "file:${cfg.customDir}/conf/oauth2_jwt_secret";
      };

      mailer = {
        ENABLED = true;
        PROTOCOL = "smtps";
        SMTP_ADDR = "smtp.purelymail.com";
        SMTP_PORT = 465;
        USER = "lweber@sakul-flee.de";
        FROM = "forgejo@sakul-flee.de";
        PASSWD_URI = "file:${cfg.customDir}/conf/smtp_password";
      };
    };
  };

  # GPG commit signing is NOT configured yet, and that is a deliberate gap rather
  # than an oversight. The k3s deployment had signing enabled, so commits made
  # after the cutover would show as unverified until this is added. It needs a
  # gnupg home directory on the `persistent` pool plus an import of the armored
  # private key, which is a separate change with its own failure modes -- and it
  # has nothing to do with proving the restore worked. Flagged so it is a
  # decision rather than a surprise.
}