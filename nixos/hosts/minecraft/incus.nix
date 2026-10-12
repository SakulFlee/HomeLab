# Incus-level definition of the "minecraft" instance.
#
# See ../paperless/incus.nix for what belongs in this file versus default.nix:
# this is the container, not the software inside it -- the volume list, the
# device map, the limits, the forward.
#
# Two things make this instance different from the ones before it:
#
#   * It is on the `default` Incus project, which is not incidental. Custom
#     volumes are project-scoped, and the Syncthing hub that mirrors
#     `minecraft-backups` lives in `default` too (see
#     ../syncthing/NOTES.md, "Replication standard", step 2). An instance in its
#     own project would produce a volume the hub cannot attach, silently.
#
#   * It has a `networkForward`. Everything else that reaches the internet does
#     it through Caddy, and Minecraft cannot: the Java protocol is a raw TCP
#     stream with no HTTP in it, so there is nothing for an L7 proxy to route.
let
  devices = {
    # Overrides the 'default' profile's eth0 with a fixed address, the same
    # shape every other instance uses.
    #
    # 10.0.0.115, checked against the LIVE instances rather than against this
    # repository, which is not the same thing. The block .100-.114 is already
    # entirely taken -- and .102 in particular is NOT free, which the repo alone
    # does not reveal: forgejo-runner declares no address at all and holds
    # 10.0.0.102 because dnsmasq assigned it one. See the DHCP note below.
    #
    #   incus list homelab: --format csv -c n4
    #
    # So .115 is simply the next address above that contiguous block.
    #
    # That "pin a static address" is the right posture here precisely because
    # DHCP is live on this bridge and draws from inside it: an unpinned instance
    # can be handed an address another instance is pinned to, and the result is
    # a duplicate IP with ARP flapping between two guests rather than an error
    # anybody is told about. forgejo-runner is currently sitting on an address
    # it did not choose, in the middle of everybody else's range. Pinning is how
    # this stays survivable.
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.115";
    };

    # The server's whole working directory: world/, plugins/, server.properties,
    # ops.json, whitelist.json, the Paper jar. Everything the k3s deployment had
    # on its `datadir-minecraft-0` PVC.
    #
    # Mounted at the root of the data volume so the load from k3s is a straight
    # copy of the PVC's contents, with no nesting to flatten. The Paper jar and
    # the fetched plugins land here too, which is why this cannot be a read-only
    # or dedicated-jar volume.
    data = {
      type = "disk";
      pool = "persistent";
      source = "minecraft-data";
      path = "/var/lib/minecraft";
    };

    # The backup archives, and NOTHING else.
    #
    # A separate volume, nested inside the data volume, for one reason: this is
    # the only part of this instance the Syncthing hub is allowed to see. If the
    # archives lived inside `minecraft-data` the hub would have to mount that
    # volume to reach them, and replicating a live world means re-shipping
    # megabytes of region files on every save and racing the server's writes.
    # Archiving first and replicating the archives makes the replicated set small,
    # immutable and append-only.
    #
    # The nesting is the same one paperless already does (media volume inside the
    # data volume, see ../paperless/incus.nix), so it is a shape this host has
    # verified rather than a new one.
    backups = {
      type = "disk";
      pool = "persistent";
      source = "minecraft-backups";
      path = "/var/lib/minecraft/backups";
    };
  };
in
{
  description = "Minecraft Paper server";

  # Comes up on apply and on host boot, like every other instance. Deliberately
  # true from the first commit even though the k3s StatefulSet sat at
  # replicaCount 0: that was mc-router's sleep state, not this instance's
  # intended one. mc-router is not being ported, so nothing here has an
  # equivalent -- the server is simply always on, which is what a world that
  # nobody is connected to costs nothing to keep running.
  autostart = true;

  # 2 CPU, and 3GiB rather than the 2GiB the k8s container was capped at.
  #
  # The cap is the interesting part. jvmOpts in ../default.nix asks for -Xmx2G,
  # and a 2GiB cgroup limit cannot hold a 2GiB heap: on top of the heap there is
  # metaspace, the code cache, Paper's own off-heap structures and the JVM's
  # native overhead, which together run a few hundred MiB. At a 2GiB limit that
  # is not "tight", it is an OOM kill a few minutes after every boot, and it
  # would look like the server crashing at random rather than a mis-sized
  # container. The headroom is what makes the heap setting survivable.
  #
  # Adjustable live with `incus config set minecraft limits.memory=4GiB`, like
  # every other instance.
  limits = {
    memory = "3GiB";
    cpu = "2";
  };

  # Both volumes on `persistent`, which is the only pool there is. There used to
  # be a second pool named `backup`, and it was merged into this one: same btrfs
  # driver, same filesystem, no quota, and nothing had ever enforced a
  # difference. Retention is declared per volume below rather than inherited from
  # a pool, which is the lesson that merge left behind.
  #
  # Consequence for anyone arriving here with "put the world on the restic'd
  # pool" in mind: `persistent` IS the restic'd one. The host's hourly restic
  # backs up /var/lib/incus/storage-pools/persistent wholesale
  # (nixos/hosts/homelab/services/backup.nix), which covers both volumes below,
  # archives included, and excludes nothing.
  volumes = [
    {
      pool = "persistent";
      name = "minecraft-data";
      description = "Minecraft world, plugins and server config";

      # The rollback for a bad world edit, a bad plugin, or a bad copy during the
      # data load. Same @daily/7d as every other data-bearing volume in this
      # repository.
      snapshots = {
        schedule = "@daily";
        expiry = "7d";
      };
    }
    {
      pool = "persistent";
      name = "minecraft-backups";
      description = "World backup archives -- the only volume the Syncthing hub replicates";

      # Redundant with the archives themselves by design. The snapshot is the
      # local rollback (an archive written by a tar that raced something); the
      # peer is the off-box copy. restic also captures this volume, so there are
      # three independent copies, which for a game world is not paranoia so much
      # as the price of it being the one thing here nobody can regenerate.
      snapshots = {
        schedule = "@daily";
        expiry = "7d";
      };
    }
  ];

  devices = devices;

  # ---------------------------------------------------------------------
  # 25565/tcp on the host's LAN address
  # ---------------------------------------------------------------------
  #
  # The reason this instance needs a forward at all is that it is the first
  # service here that is not HTTP. Caddy terminates TLS and routes by hostname
  # for everything else; the Minecraft handshake carries a server address and a
  # protocol version number and then nothing that resembles a request line, so
  # there is nothing to route on and no TLS to terminate -- the vanilla protocol
  # is TCP 25565 in the clear.
  #
  # So this is the same DNAT caddy already uses, and it coexists with the
  # incumbent for exactly the documented reason: Incus implements a forward as an
  # nftables DNAT rule rather than a socket bind, so packets aimed at
  # 192.168.178.200 are rewritten before socket lookup while Traefik's listener
  # on 0.0.0.0:25565 keeps holding the port. Traefik keeps serving until this
  # rule exists, which is what makes the cutover and its rollback one command
  # each (see ../minecraft/README.md).
  #
  # This shares 192.168.178.200 with caddy's 80/443, forgejo's 22, dns' 53 and
  # syncthing's 22000. apply.sh reconciles the union of every instance's ports on
  # an address, so declaring it here neither disturbs the others nor depends on
  # their specs.
  #
  # 25565/udp is deliberately absent. Nothing in this deployment speaks it: the
  # three plugins carried over from k3s (Portalis, WorldEdit, WorldEditSUI) are
  # server-side and make no client connection, and the vanilla protocol is TCP.
  # fluxer forwards 7882/udp because LiveKit genuinely needs it; there is no
  # equivalent here to copy.
  networkForward = {
    listenAddress = "192.168.178.200";

    # Derived from devices.eth0 above so the two cannot drift.
    targetAddress = devices.eth0."ipv4.address";

    # One entry per port, never "25565,25577" in a single entry:
    # `incus network forward port add` treats a comma list as ONE grouped entry,
    # which then cannot be removed one port at a time afterwards.
    ports = [
      {
        protocol = "tcp";
        listenPort = 25565;
      }
    ];
  };
}