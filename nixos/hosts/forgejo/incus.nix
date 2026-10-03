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
      pool = "backup";
      name = "forgejo-repositories";
      description = "Git repositories -- the must-survive data from the k3s PV";
    }
    {
      # Deliberately NOT restic'd. A live PGDATA directory that is copied
      # mid-write is a corrupt PGDATA directory, which is worse than none. The
      # authoritative artefact is a pg_dump landing in 'backup' -- see
      # apps/forgejo/dump-cronjob.yaml. The split is structural, not a
      # convention anyone has to remember.
      pool = "persistent";
      name = "forgejo-postgres";
      # Accurate only while services.postgresql.dataDir is
      # /var/lib/postgresql/data. See the device of the same name below.
      description = "PostgreSQL PGDATA -- never file-back-up, pg_dump only";
    }
    {
      # Also persistent: LFS objects are content-addressed blobs, and restoring
      # them requires a matching repository set. Dumped alongside the repos.
      pool = "persistent";
      name = "forgejo-lfs";
      description = "Git LFS objects";
    }
  ];

  devices = {
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.101";
    };

    repositories = {
      type = "disk";
      pool = "backup";
      source = "forgejo-repositories";
      path = "/var/lib/forgejo/data/git";
    };

    postgres = {
      # This path and services.postgresql.dataDir are the same string on
      # purpose, and the coupling is not obvious from either side.
      #
      # The postgresql module's default dataDir is /var/lib/postgresql/<major>,
      # so a volume mounted at /var/lib/postgresql/data is mounted somewhere the
      # database never looks. That is not hypothetical: it is what happened here,
      # and it failed completely silently -- the database came up, migrated, and
      # served HTTP with 72MB of real data on the container's root disk while this
      # volume sat empty. Caught by asking the running server
      # `SHOW data_directory`, after a cleanup appeared to do nothing.
      #
      # Changing one without the other puts the data back on the root disk.
      type = "disk";
      pool = "persistent";
      source = "forgejo-postgres";
      path = "/var/lib/postgresql/data";
    };

    lfs = {
      type = "disk";
      pool = "persistent";
      source = "forgejo-lfs";
      path = "/var/lib/forgejo/data/lfs";
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
      # 0440 root:forgejo, not the 0400 root:root default, because Forgejo now
      # reads these itself via the *_URI settings rather than systemd handing
      # them over as credentials. At 0400 root:root the forgejo user cannot open
      # them -- and one of the five already was, having been created before the
      # setgid bit on customDir/conf existed.
      mode = "0440";
      group = "forgejo";
      file = "secret_key";
      dir = "/var/lib/forgejo/custom/conf";
      source = "/run/secrets/forgejo_secret_key";
    }
    {
      format = "raw";
      # 0440 root:forgejo, not the 0400 root:root default, because Forgejo now
      # reads these itself via the *_URI settings rather than systemd handing
      # them over as credentials. At 0400 root:root the forgejo user cannot open
      # them -- and one of the five already was, having been created before the
      # setgid bit on customDir/conf existed.
      mode = "0440";
      group = "forgejo";
      file = "internal_token";
      dir = "/var/lib/forgejo/custom/conf";
      source = "/run/secrets/forgejo_internal_token";
    }
    {
      format = "raw";
      # 0440 root:forgejo, not the 0400 root:root default, because Forgejo now
      # reads these itself via the *_URI settings rather than systemd handing
      # them over as credentials. At 0400 root:root the forgejo user cannot open
      # them -- and one of the five already was, having been created before the
      # setgid bit on customDir/conf existed.
      mode = "0440";
      group = "forgejo";
      file = "oauth2_jwt_secret";
      dir = "/var/lib/forgejo/custom/conf";
      source = "/run/secrets/forgejo_jwt_secret";
    }
    {
      format = "raw";
      # 0440 root:forgejo, not the 0400 root:root default, because Forgejo now
      # reads these itself via the *_URI settings rather than systemd handing
      # them over as credentials. At 0400 root:root the forgejo user cannot open
      # them -- and one of the five already was, having been created before the
      # setgid bit on customDir/conf existed.
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
      # 0440 root:forgejo, not the 0400 root:root default, because Forgejo now
      # reads these itself via the *_URI settings rather than systemd handing
      # them over as credentials. At 0400 root:root the forgejo user cannot open
      # them -- and one of the five already was, having been created before the
      # setgid bit on customDir/conf existed.
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
