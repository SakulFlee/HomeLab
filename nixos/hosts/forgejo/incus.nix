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
      pool = "persistent";
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
      # On `persistent` with everything else. There used to be a second pool
      # named `backup`; that name was a convention, not a mechanism (see
      # hosts/homelab/services/incus.nix), and it was merged away.
      #
      # The snapshot below is what that convention now actually means. `backup`
      # only ever named an intent; nothing acted on it until the schedule was
      # written here, where the volume's own entry declares how it is rolled
      # back. See nixos/incus-instances.nix for why it lives here rather than in
      # a list.
      pool = "persistent";
      name = "forgejo-data";
      description = "Everything Forgejo stores: repos, LFS, attachments, packages, avatars";

      # @daily, 7d.
      #
      # Not hourly: git objects are immutable once written, so the hourly
      # snapshots restic used to take of this volume were near-identical
      # snapshots of a directory that only changed when someone pushed. Daily
      # matches how this data actually changes and costs an eighth as much.
      #
      # Not 30d: the rollback target for a bad push is the state a few hours
      # ago, and Forgejo's repositories are also replicated by Syncthing -- so
      # the long tail here is duplicating a copy that exists elsewhere rather
      # than protecting something unique. Raise it if that stops being true.
      snapshots = {
        schedule = "@daily";
        expiry = "7d";
      };
    }
    {
      # Separate from the above because it is a mount for a running database, not
      # a data directory, and because it has a different lifecycle: this one is
      # worthless if torn.
      #
      # The earlier comment here said "Deliberately NOT restic'd... restore from
      # pg_dump, never from a file copy", and argued that a live PGDATA copied
      # mid-write is a corrupt PGDATA directory. The conclusion was right and the
      # premise was wrong, because Incus snapshots are not a file copy: the
      # snapshot is a btrfs subvolume sharing every extents with the live volume
      # and differing only in the blocks written since. Nothing is walked,
      # nothing is read while the database is running, and the WAL is captured in
      # the same instant as the data pages it describes -- so the snapshot is
      # crash-consistent, which is the guarantee a PGDATA copy taken while
      # postgres is up can never give. Crash-consistent is not the same as clean,
      # and the restored database will run recovery on start, but it is a real
      # PGDATA directory rather than a torn one.
      #
      # There is still no pg_dump here. That is a separate decision about what a
      # *logical* backup is for, and it is not this file's to make: a dump cannot
      # restore the instance if the host is gone, and a snapshot cannot be
      # restored onto a different PostgreSQL major version or inspected without
      # booting it. The snapshot is the rollback layer; if a dump is ever wanted
      # it belongs beside it, not instead of it.
      #
      # This path and services.postgresql.dataDir are the same string on purpose.
      # The module's default dataDir is /var/lib/postgresql/<major>, so a volume
      # mounted at /var/lib/postgresql/data is mounted somewhere the database
      # never looks -- and did, silently, with 72MB of live data on the root
      # disk. Changing one without the other puts it back.
      pool = "persistent";
      name = "forgejo-postgres";
      description = "PostgreSQL PGDATA -- live mount for the database, snapshot for rollback";

      # Snapshots, declared on the volume rather than in a list with the rest of
      # the backup settings, so that a service carries its own rollback policy
      # into Incus when it moves out of k3s. See nixos/incus-instances.nix.
      #
      # 7d, not 30d: this is rollback for a mistake made an hour ago, and a
      # PGDATA volume that cannot be rolled back to last week is not obviously
      # more valuable than one that costs a seventh of the space.
      snapshots = {
        schedule = "@daily";
        expiry = "7d";
      };
    }
  ];

  devices = devices;

  # Port 22 on the host's LAN address, DNAT'd to this instance's sshd.
  #
  # This is the whole reason the host's own SSH moved to 2222 -- see
  # ../../modules/ssh.nix. Incus implements a network forward as an nftables DNAT
  # rule, which is per-port and unconditional: there is no way to send port 22 to
  # Forgejo only for SSH push traffic and keep it for the administrator. Exactly one
  # of the two could keep 22, and git transport is the one that cannot move, because
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