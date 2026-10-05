# Incus-level definition of the "forgejo" instance.
#
# See ../../caddy/incus.nix for what belongs in this file versus default.nix.
#
# The let/in wrapper exists so `networkForward.targetAddress` can be written as
# devices.eth0."ipv4.address" rather than repeating the literal "10.0.0.101".
# Caddy does the same thing for its own forward. Without it:
#
#   error: undefined variable 'devices'
#     at hosts/forgejo/incus.nix:119:21
#
let
  devices = {
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.101";
    };

    data = {
      type = "disk";
      pool = "backup";
      source = "forgejo-data";
      path = "/var/lib/forgejo/data";
    };

    postgres = {
      type = "disk";
      pool = "persistent";
      source = "forgejo-postgres";
      path = "/var/lib/postgresql/data";
    };
  };
in
{
  description = "Git forge (Forgejo)";

  autostart = true;

  # Forgejo is heavier than Caddy: a Go binary plus a Postgres server, and
  # git-receive-pack spikes CPU hard when a large repository is pushed. 4
  # cores and 2GiB leaves room for both to run without the whole box stalling.
  limits = {
    memory = "2GiB";
    cpu = "4";
  };

  volumes = [
    {
      # ONE volume for everything Forgejo stores, mounted at its APP_DATA_PATH.
      #
      # This started as three -- repositories, lfs, postgres -- and grew to six
      # when the k3s PV turned out to hold attachments, packages and avatars as
      # well. That was modelling the k3s deployment's directory layout instead of
      # Forgejo's, and it bought nothing: one device to mount, one thing to back
      # up, one path to restore into, and a set of volume descriptions that each
      # had to be kept true by hand.
      #
      # Mounting at /var/lib/forgejo/data puts it exactly where Forgejo already
      # looks, because APP_DATA_PATH defaults to `data` under WORK_PATH. So
      #
      #   git/           repositoryRoot, set in default.nix
      #   lfs/           lfs.contentDir, the module's default
      #   attachments/   Forgejo's default
      #   avatars/       Forgejo's default
      #   packages/      Forgejo's default
      #
      # all resolve inside it with no further configuration, which is the same
      # layout the k3s PV had. The restore is `cp -a` of that PV's contents into
      # this volume, minus the directories Forgejo regenerates.
      #
      # On `backup` rather than `persistent`: that pool name is a convention, not
      # a mechanism (see hosts/homelab/services/incus.nix), and if it is ever
      # backed up at all this is the volume that matters.
      pool = "backup";
      name = "forgejo-data";
      description = "Everything Forgejo stores: repos, LFS, attachments, packages, avatars";
    }
    {
      # Separate from the above because it is a mount for a running database, not
      # a data directory, and because it has a different lifecycle: this one is
      # worthless if torn, and a pg_dump is the authoritative artefact.
      #
      # Deliberately NOT restic'd. A live PGDATA copied mid-write is a corrupt
      # PGDATA directory, which is worse than none -- so the argument against
      # backing it up was never that a copy does harm, only that a copy must
      # never be the thing you restore from. Worth being precise about, because
      # the earlier version of this comment conflated the two and used the first
      # claim to justify the second.
      #
      # This path and services.postgresql.dataDir are the same string on purpose.
      # The module's default dataDir is /var/lib/postgresql/<major>, so a volume
      # mounted at /var/lib/postgresql/data is mounted somewhere the database
      # never looks -- and did, silently, with 72MB of live data on the root
      # disk. Changing one without the other puts it back.
      pool = "persistent";
      name = "forgejo-postgres";
      description = "PostgreSQL PGDATA -- restore from pg_dump, never from a file copy";
    }
  ];

  devices = devices;

  # Port 22 on the host's LAN address, DNAT'd to this instance's sshd.
  #
  # This is the whole reason the host's own SSH moved to 2222 -- see
  # ../../modules/ssh.nix. Incus implements a network forward as an nftables DNAT
  # rule, which is per-port and unconditional: there is no way to send port 22 to
  # Forgejo only for `git@` and keep it for the administrator. Exactly one of the
  # two could keep 22, and git transport is the one that cannot move, because
  # SSH_PORT=22 is what Forgejo advertises in every clone URL.
  #
  # `incus network forward` accepts several ports on one listen address (Caddy
  # already holds 80 and 443 on 192.168.178.200), so this adds a port rather than
  # a second forward. apply.sh converges the port list: it removes entries the
  # spec no longer declares and adds the ones it does, so this is reconciled
  # rather than applied once.
  #
  # Take this away with:
  #   incus network forward port remove incusbr0 192.168.178.200 tcp 22
  networkForward = {
    # The host's LAN address. Must match the host's own address; nothing
    # validates that, and a forward listening somewhere nothing answers is the
    # quietest possible failure.
    listenAddress = "192.168.178.200";

    # Derived from devices.eth0 above so the two cannot drift.
    targetAddress = devices.eth0."ipv4.address";

    ports = [
      {
        protocol = "tcp";
        listenPort = 22;
      }
    ];
  };

  # The git hooks, which name the forgejo binary and its config by absolute path.
  # Read by incus/apply.sh's sync_forgejo_hooks, which rewrites them on every
  # reconcile.
  #
  # This exists because the hooks inherited from the k3s Docker image name paths
  # that do not exist here -- /usr/local/bin/gitea and /data/gitea/conf/app.ini --
  # and a set of hooks pointing at a missing binary does NOT stop a push. git
  # reports success, the branch lands, and Forgejo's own side effects (the
  # pull-request link, webhooks, mirror sync, the activity feed) silently never
  # happen. Proven rather than assumed: every push completed with exit 0 while
  # every hook was broken.
  #
  # The binary is asserted here and verified against forgejo.service's own
  # ExecStart at apply time, so a nixpkgs bump that changes the store path fails
  # loudly instead of quietly re-breaking all 265 hook files. Nothing writes the
  # path down twice.
  #
  # `config` is the module's own customDir/conf/app.ini, which is where
  # render_secrets puts it and where the module's *_URI settings read it from.
  # No `binary` here, deliberately. It is a /nix/store path, and writing it in two
  # places is exactly the fragility being removed: this file is a plain `import`
  # of a literal with no module arguments at all, so it cannot read
  # config.services.forgejo.package, and a hardcoded store path in a config file
  # is a value that silently rots on the next nixpkgs bump. apply.sh reads the
  # path out of forgejo.service's own ExecStart inside the guest instead -- one
  # source of truth, and the one that is actually running.
  #
  # The two paths that ARE stable go here, because they are configuration rather
  # than build output: the module's stateDir and customDir, neither of which
  # changes when nixpkgs moves.
  forgejoHooks = {
    repositoryRoot = "/var/lib/forgejo/data/git/gitea-repositories";
    config = "/var/lib/forgejo/custom/conf/app.ini";
  };

  # Guest units that operate on files the HOST reconciler writes, and so have to be
  # re-run once those files exist. incus/apply.sh reads this list and restarts each
  # unit after render_secrets.
  #
  # forgejo-config-access is the case that made this necessary. Its ExecStart runs
  # at BOOT, from WantedBy=multi-user.target, and app.ini is written by
  # render_secrets afterwards -- measured eight seconds apart on the live instance:
  #
  #   03:05:01  chmod: cannot access '/var/lib/forgejo/custom/conf/app.ini'
  #   03:05:09  app.ini mtime
  #
  # So the parent directories got their o+x, the two files inside conf/ did not,
  # and the unit exited 0. `git` then could not read app.ini and every clone failed
  # with `Could not chdir to home directory /var/lib/forgejo`, which names the home
  # directory and not the missing chmod.
  #
  # A list rather than a single name, so the reconciler stays generic: nothing
  # here knows what these units do, only that they need to run again.
  afterRenderSecrets = [ "forgejo-config-access.service" ];

  # Secrets the host decrypts and writes into this instance. incus/apply.sh reads
  # `source` on the host and writes the bytes to `dir/file` inside the instance.
  #
  # dir = the Forgejo module's customDir/conf, and every filename below is one
  # the module already names. That is deliberate, and it is what makes this work
  # at all:
  #
  #   * services.forgejo declares defaults for four of these -- secret_key,
  #     internal_token, oauth2_jwt_secret, lfs_jwt_secret -- so pointing them
  #     elsewhere needs `mkForce` to override the module's own definition.
  #   * Its forgejo-secrets unit generates any of them that is EMPTY, and is
  #     sandboxed with ReadWritePaths = [ customDir ]. On the first boot, before
  #     anything has been rendered, it would try to create the missing ones
  #     wherever they had been pointed and be denied by its own sandbox. That
  #     unit is Required by forgejo.service, so Forgejo would never start.
  #
  # Writing them where the module already looks makes the generator a no-op,
  # needs no mkForce, and cannot fail that way.
  #
  # format = "raw" for all five: these are values app.ini has to receive whole,
  # and `env` would wrap each in NAME=value, which is not what a Forgejo secret
  # wants. Raw is also why each one is a separate file.
  #
  # The first four are the k3s deployment's values, reused on purpose. From
  # Forgejo's own configuration cheat sheet: "SECRET_KEY: Global secret key. This
  # key is VERY IMPORTANT; if you lose it, data encrypted by it (like 2FA secrets)
  # can no longer be decrypted." So a freshly generated SECRET_KEY would leave
  # any two-factor secrets in the database being restored permanently
  # undecryptable, with nothing in the logs. The rest sign tokens clients
  # already hold.
  renderedSecrets = [
    {
      format = "raw";
      # 0440 root:forgejo, not the 0400 root:root default, because Forgejo reads
      # these itself via the *_URI settings rather than systemd handing them over
      # as credentials. At 0400 root:root the forgejo user cannot open them.
      mode = "0440";
      group = "forgejo";
      file = "secret_key";
      dir = "/var/lib/forgejo/custom/conf";
      source = "/run/secrets/forgejo_secret_key";
    }
    {
      format = "raw";
      mode = "0440";
      group = "forgejo";
      file = "internal_token";
      dir = "/var/lib/forgejo/custom/conf";
      source = "/run/secrets/forgejo_internal_token";
    }
    {
      format = "raw";
      mode = "0440";
      group = "forgejo";
      file = "oauth2_jwt_secret";
      dir = "/var/lib/forgejo/custom/conf";
      source = "/run/secrets/forgejo_jwt_secret";
    }
    {
      format = "raw";
      mode = "0440";
      group = "forgejo";
      file = "lfs_jwt_secret";
      dir = "/var/lib/forgejo/custom/conf";
      source = "/run/secrets/forgejo_lfs_secret";
    }
    # The mailer password has no module default, so the guest points at it
    # explicitly (services.forgejo.secrets.mailer.PASSWD).
    {
      format = "raw";
      mode = "0440";
      group = "forgejo";
      file = "smtp_password";
      dir = "/var/lib/forgejo/custom/conf";
      source = "/run/secrets/forgejo_smtp_password";
    }
  ];

  # Units inside the instance that read a rendered file, and that must therefore
  # be restarted when one changes. forgejo.service is the only consumer: the
  # secrets go in as systemd credentials, which are read once at process start.
  secretConsumers = [ "forgejo.service" ];
}