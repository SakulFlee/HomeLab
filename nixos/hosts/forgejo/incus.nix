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
}
