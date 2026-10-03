# Incus-level definition of the "forgejo" instance.
#
# See ../../caddy/incus.nix for what belongs in this file versus default.nix.
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

  devices = {
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.101";
    };

    # Forgejo's APP_DATA_PATH. See the forgejo-data volume above.
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