# Incus-level definition of the "paperless" instance.
#
# See ../syncthing/incus.nix for what belongs in this file versus default.nix:
# this is the container, not the software inside it -- the volume list, the
# device map, the limits.
#
# Paperless is VPN-only, exactly like the k3s deployment it replaces. Caddy's
# vhost sits on the host's wireguard gate, and Caddy reaches this instance over
# incusbr0 at 10.0.0.105. There is deliberately NO networkForward here: nothing
# puts a port on the LAN address, so this instance is reachable only from the
# host bridge and through the VPN gate -- same posture as before, same host gating
# the traffic.
let
  devices = {
    # Overrides the 'default' profile's eth0 with a fixed address, the same
    # shape every other instance uses.
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.105";
    };

    # ---------------------------------------------------------------
    # Data-bearing volumes, one per thing that must outlive the container.
    # All on `persistent` with the same @daily/7d snapshot policy as forgejo
    # and syncthing; the notes under each entry say what the snapshot is the
    # rollback FOR.
    # ---------------------------------------------------------------

    data = {
      type = "disk";
      pool = "persistent";
      source = "paperless-data";
      path = "/var/lib/paperless";
    };

    media = {
      type = "disk";
      pool = "persistent";
      source = "paperless-media";
      path = "/var/lib/paperless/media";
    };

    postgres = {
      type = "disk";
      pool = "persistent";
      source = "paperless-postgres";
      path = "/var/lib/postgresql/data";
    };
  };
in
{
  description = "Paperless-ngx document management";

  # Comes up on apply and on host boot, like every other service. This was
  # false for the migration commits: the volumes were loaded and the dump
  # restored while the instance was stopped and services.paperless disabled.
  autostart = true;

  # Paperless runs PostgreSQL, redis, celery workers and ocrmypdf/tesseract in
  # here; OCR is per-document CPU-bound, so cores matter more than RAM. 4/4GiB,
  # adjustable live with `incus config set` like every other instance.
  limits = {
    memory = "4GiB";
    cpu = "4";
  };

  volumes = [
    {
      pool = "persistent";
      name = "paperless-data";
      description = "Paperless state: tantivy index, logs, secret key, migrate version";

      # Mounted at the module's dataDir (/var/lib/paperless). The k3s deployment
      # this replaces had a data PV whose root WAS the app-state dir: index/,
      # log/, media/ together, so the volume root here corresponds exactly and
      # the loader streams the tarball in at the volume root. The snapshot is
      # the rollback for the index: it is derived data, so the dump does not
      # cover it.
      snapshots = {
        schedule = "@daily";
        expiry = "7d";
      };
    }
    {
      pool = "persistent";
      name = "paperless-media";
      description = "Documents, archive, thumbnails -- the first replicated volume";

      # Mounted at the module's mediaDir (/var/lib/paperless/media). This is the
      # first entry in nixos/replicated-volumes.nix: the Syncthing hub mounts it
      # read-only and shares it as a sendonly folder (see
      # ../syncthing/NOTES.md). The producer has to write `.stfolder` at the
      # volume root itself because the hub cannot; default.nix pins the loader's
      # uid/gid and carries a tmpfiles rule that replants the marker.
      snapshots = {
        schedule = "@daily";
        expiry = "7d";
      };
    }
    {
      pool = "persistent";
      name = "paperless-postgres";
      description = "PostgreSQL PGDATA -- snapshot is the in-place rollback";

      # Same rationale as forgejo-postgres: a crash-consistent btrfs snapshot is
      # the rollback layer for the live database. The logical dump that moved
      # the data here comes from k3s and dies when k3s is torn down; this is
      # what remains, so daily snapshots are the recovery window.
      snapshots = {
        schedule = "@daily";
        expiry = "7d";
      };
    }
  ];

  devices = devices;
}