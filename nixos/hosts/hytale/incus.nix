# Incus-level definition of the "hytale" instance.
#
# See ../minecraft/incus.nix for what belongs in this file versus default.nix:
# the volume list, the device map, the limits, the forward. The short version is
# that this file describes the *container* and default.nix describes the
# software in it.
#
# Three things are load-bearing about this instance and each one is a decision
# rather than a default:
#
#   * It is on the `default` Incus project, because its backup volume has to be
#     attachable by the Syncthing hub, which also lives in `default`. Custom
#     volumes are project-scoped, so an instance in its own project would
#     produce a volume the hub cannot see, and nothing would say so. See
#     ../syncthing/NOTES.md, "Replication standard", step 2.
#
#   * It has a `networkForward`, for the same reason minecraft does: Hytale
#     speaks QUIC over UDP and there is no HTTP in the protocol for Caddy to
#     route. See "5520/udp" below.
#
#   * Its backups are produced BY THE SERVER, inside the server's own cgroup,
#     rather than by a unit that stops it. That is only possible because Hytale
#     flushes its resources before it zips them; see ../hytale/default.nix for
#     the evidence and for why Minecraft could not do this.
let
  devices = {
    # Overrides the 'default' profile's eth0 with a fixed address, the same
    # shape every other instance uses.
    #
    # 10.0.0.116, checked against the LIVE instances rather than against this
    # repository:
    #
    #   incus list homelab: --format csv -c n4
    #
    # The .100-.115 block is now entirely taken, and two of those are not
    # visible from this repository at all, which is why the live list is the one
    # that has to be trusted:
    #
    #   .110  wireguard's second NIC (eth1 on incusbr0)
    #   .114  website -- a VM on a macvlan, so it is on the LAN rather than the
    #         bridge, but it holds the address and nothing else may have it
    #   .102  forgejo-runner, which declares no address and was given one by DHCP
    #
    # (`incus list homelab:` only shows the default project, so .101/forgejo is
    # absent from that output entirely. It is in the `forgejo` project.)
    #
    # Pinning is how this stays survivable: DHCP is live on incusbr0 and draws
    # from inside the subnet, so an unpinned instance can be handed an address
    # another instance already holds, and the result is ARP flapping between
    # two guests rather than an error anybody is told about.
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.116";
    };

    # The whole working directory: Assets.zip, Server/ (the jar, the AOT cache,
    # config.json, universe/, mods/, logs/), and the launcher scripts. What the
    # k3s deployment had on its `hytale-hytale-0` PVC.
    #
    # Mounted at the root rather than nested, so loading the k3s PVC is a
    # straight copy of its contents with no nesting to flatten -- the same
    # decision minecraft made for the same reason.
    data = {
      type = "disk";
      pool = "persistent";
      source = "hytale-data";
      path = "/var/lib/hytale";
    };

    # The backup archives, and NOTHING else.
    #
    # A separate volume, nested inside the data volume, for the reason
    # ../minecraft/incus.nix gives for minecraft-backups: this is the only part
    # of this instance the Syncthing hub is allowed to see. Replicating the live
    # universe instead would mean re-shipping 178 MB of region blobs whenever a
    # region is rewritten, and racing the server's writes for them.
    #
    # The path matters as much as the separation. Hytale is told to write its
    # archives to `backups` RELATIVE to its working directory, and its working
    # directory is Server/ (that is where config.json, universe/ and mods/ all
    # live, and the launcher's own start.sh relies on it). So this mount point
    # and that relative path are the same directory, and `--backup-dir backups`
    # is upstream's own default string. Nothing is invented here.
    backups = {
      type = "disk";
      pool = "persistent";
      source = "hytale-backups";
      path = "/var/lib/hytale/Server/backups";
    };

    # The Hytale downloader's OAuth credentials, and nothing else.
    #
    # A whole volume for one ~1.3 kB file, which looks absurd until you look at
    # what the other two options actually cost:
    #
    #   * On hytale-data it would land inside the hourly btrfs snapshots, so a
    #     day of snapshots would each hold a live copy of a refresh token for a
    #     game account. caddy-secrets solves exactly this by having no
    #     `snapshots` block at all, and the omission there is the point.
    #   * As a `renderedSecrets` entry it would be actively wrong. apply.sh
    #     diffs a rendered file against the host's sops value and REWRITES it
    #     on every run, and incus-reconcile.timer runs `--all` every fifteen
    #     minutes. The downloader re-saves its own credentials whenever the
    #     tokens refresh, so sops would overwrite a refreshed token with a stale
    #     one every quarter of an hour, and the next download would fail with a
    #     401 at exactly the moment a patch had landed.
    #
    # So it is unmanaged, like caddy's ACME keys: written by the downloader
    # itself, pointed at explicitly with -credentials-path, and never touched by
    # anything else in this repository. It survives a recreate because the
    # volume does.
    secrets = {
      type = "disk";
      pool = "persistent";
      source = "hytale-secrets";
      path = "/var/lib/hytale-secrets";
    };
  };
in
{
  description = "Hytale dedicated game server";

  autostart = true;

  # 8GiB is unchanged from the k3s container's limit, and it is not negotiable
  # against the -Xmx4G in ../default.nix: on top of the heap there is metaspace,
  # the code cache, the 178 MB asset map being mmapped and the JVM's native
  # overhead. At a limit below the heap plus that, the symptom is not "tight",
  # it is an OOM kill some minutes after every boot.
  #
  # cpu 4, up from the 2 the k3s container was capped at, and the reason is
  # that the cap means something different now. k3s enforced 2000m as a limit
  # too, but the container also REQUESTED only 250m, so the scheduler had every
  # reason to leave the rest of the node for it. Incus's `limits.cpu` with no
  # priority is a flat CFS quota on the whole cgroup, and the server now does
  # its own backup work inside that cgroup: Universe.runLockedBackup() calls
  # flushAll() and then deflates 178 MB of region data, on top of serving
  # players. Capping that at two cores would take the budget out of the game.
  #
  # Adjustable live with `incus config set hytale limits.memory=12GiB`, like
  # every other instance.
  limits = {
    memory = "8GiB";
    cpu = "4";
  };

  # All three on `persistent`, which is the only pool there is (`backup` was
  # merged into it). Retention is declared per volume rather than inherited,
  # which is the lesson that merge left behind.
  #
  # @hourly rather than the @daily/7d the older volumes use, and it is worth
  # being explicit about why this one is not that. A btrfs snapshot copies
  # nothing: it costs only the extents written AFTER it was taken, so cold data
  # is free and only rewrite-heavy data is expensive. This volume is the good
  # case, measured on the live deployment before the migration:
  #
  #   Assets.zip + jar + .aot.config + Licenses   ~3.6 GB   written ONCE, at
  #                                                            download, never
  #                                                            touched again
  #   chunks/*.region.bin                          178 MB   15 whole-file blobs
  #                                                            of 12-32 MB, last
  #                                                            written Aug 26-30
  #   resources/ + players/ JSON                   220 kB   rewritten constantly
  #
  # So the hot-write set is ~220 kB and the 178 MB of region blobs is cold,
  # which puts an hourly tier at a few MB a day rather than at 178 MB a day.
  # 24 hours of expiry keeps that bounded and leaves the durable history to the
  # daily archive that goes off-box to Dendra.
  #
  # `24H` and not `24h`: Incus's duration grammar is S M H d w m y, where H is
  # uppercase HOURS and lowercase m is MONTHS. apply.sh validates this field
  # against exactly that grammar before writing anything, so a lowercase h is
  # rejected with
  #
  #   snapshots.expiry '24h', which is not a duration expression
  #
  # and `7d` is the shape the older volumes use. Caught by running the
  # validator's own regex rather than by reading it.
  #
  # minecraft-data is the counterexample to "make everything hourly" and is
  # deliberately NOT changed here: Paper rewrites region files continuously while
  # players are online, which is the shape that makes hourly snapshots
  # expensive, and that is a separate decision with a measurement behind it.
  volumes = [
    {
      pool = "persistent";
      name = "hytale-data";
      description = "Hytale assets, server jar, universe (worlds/players), mods and config";

      snapshots = {
        schedule = "@hourly";
        expiry = "24H";
      };
    }
    {
      pool = "persistent";
      name = "hytale-backups";
      description = "Hytale's own universe archives -- the only volume the Syncthing hub replicates";

      # Hourly here for a different reason than the volume above. The archives
      # are immutable once written, so the snapshots are nearly free; what they
      # buy is a bound on the blast radius of hytale-backup.service, which is
      # the one unit in this instance that DELETES anything
      # (`find backups -name '*.zip' -mtime +7 -delete`). A snapshot taken
      # before each run means a misfire costs an hour of archives rather than
      # the whole retention window.
      snapshots = {
        schedule = "@hourly";
        expiry = "24H";
      };
    }
    {
      # No `snapshots` block, and the omission is the point: this volume holds a
      # refresh token for a game account. Deliberately left unscheduled rather
      # than excluded by a list somewhere, so the reason lives with the volume
      # it applies to -- the same reasoning as caddy-secrets.
      pool = "persistent";
      name = "hytale-secrets";
      description = "Hytale downloader OAuth credentials -- unsnapshotted on purpose";
    }
  ];

  devices = devices;

  # ---------------------------------------------------------------------
  # 5520/udp on the host's LAN address
  # ---------------------------------------------------------------------
  #
  # The reason this instance needs a forward at all is that it is not HTTP.
  # Hytale runs QUIC over UDP: a TLS-derived transport with its own connection
  # migration and its own congestion control, addressed by IP and port with no
  # hostname, no path and no request line anywhere in it. There is nothing for
  # an L7 proxy to route and no TLS for it to terminate -- upstream states the
  # transport outright and says "TCP forwarding is not required".
  #
  # So this is the same DNAT minecraft uses, and it is safe to add while the
  # incumbent still holds the port for exactly the documented reason: Incus
  # implements a forward as an nftables DNAT rule rather than a socket bind, so
  # packets aimed at 192.168.178.200 are rewritten in PREROUTING/OUTPUT before
  # socket lookup while Traefik's listener on 0.0.0.0:5520/udp keeps the port
  # and simply stops being reached. See ../caddy/incus.nix and incus/README.md.
  #
  # This shares 192.168.178.200 with caddy's 80/443, forgejo's 22, dns's 53,
  # syncthing's 22000 and minecraft's 25565. apply.sh reconciles the UNION of
  # every instance's ports on an address, so declaring it here neither disturbs
  # the others nor depends on their specs.
  #
  # Rollback, effective immediately, because Traefik never stopped holding the
  # port:
  #
  #   incus network forward port remove incusbr0 192.168.178.200 udp 5520
  #
  # One entry, never "5520,5521" in a single entry: `incus network forward port
  # add` treats a comma list as ONE grouped entry, which then cannot be removed
  # one port at a time afterwards.
  networkForward = {
    listenAddress = "192.168.178.200";

    # Derived from devices.eth0 above so the two cannot drift.
    targetAddress = devices.eth0."ipv4.address";

    ports = [
      {
        protocol = "udp";
        listenPort = 5520;
      }
    ];
  };

  # No renderedSecrets, deliberately, and it is a decision rather than an
  # omission. This instance's only secret is the downloader's OAuth credential,
  # and it CANNOT be rendered by the host: the downloader rewrites that file
  # itself whenever its tokens refresh, so any host-managed copy would race it
  # and win, and the next download would fail with a 401. The file lives on
  # hytale-secrets, which is unsnapshotted and unmanaged. See the `secrets`
  # device above for the whole argument.
  renderedSecrets = [ ];

  # Nothing consumes a rendered secret, so nothing needs restarting after one.
  secretConsumers = [ ];
}
