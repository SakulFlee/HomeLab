# Incus-level definition of the "syncthing" instance.
#
# See ../caddy/incus.nix for what belongs in this file versus default.nix: this
# is the container, not the software inside it -- limits, volumes, the network
# device and the 22000 forward.
#
# The let/in wrapper exists so `networkForward.targetAddress` can be written as
# devices.eth0."ipv4.address" rather than repeating the literal, the same shape
# caddy/forgejo/dns use.
let
  devices = {
    # Overrides the 'default' profile's eth0 with a fixed address. The profile
    # supplies type/name/network; only the address is added, so the instance
    # still gets a veth on incusbr0 and NAT egress.
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.104";
    };

    # Config, keys and index database. The module's configDir resolves to
    # /var/lib/syncthing/.config/syncthing, inside this mount, so a recreate
    # keeps the device identity and does not re-index from scratch.
    syncthing-config = {
      type = "disk";
      pool = "persistent";
      source = "syncthing-config";
      path = "/var/lib/syncthing";
    };

    # The synced data itself. Unsized: start at whatever it is and let it grow,
    # since the point is to hold a peer's personal files.
    syncthing-data = {
      type = "disk";
      pool = "persistent";
      source = "syncthing-data";
      path = "/data";
    };
  };
in
{
  description = "Syncthing replication hub";

  autostart = true;

  # Syncthing holds an index proportional to the number of files, not their
  # size, and fsWatcher holds one inotify watch per directory, so memory scales
  # with the file COUNT. 2GiB/2 CPU is generous for a personal folder and still
  # adjustable live with `incus config set`, like every other instance.
  limits = {
    memory = "2GiB";
    cpu = "2";
  };

  volumes = [
    {
      # Carries the certificate that IS this device's identity. Losing it
      # changes the server's device ID and breaks every peer until they re-add
      # it, so the snapshot is the rollback for a bad config rather than for the
      # data -- which lives in syncthing-data.
      pool = "persistent";
      name = "syncthing-config";
      description = "Syncthing config, TLS identity and index database";

      snapshots = {
        schedule = "@daily";
        expiry = "7d";
      };
    }
    {
      # The synced files. Snapshotted on the same policy as every other
      # data-bearing volume: that snapshot is the rollback for a bad delete or
      # overwrite a peer propagated before anyone noticed. The off-box copy is
      # the peer itself, which is the whole point of Syncthing.
      #
      # This sits on `persistent` like everything else, so restic's pool-wide
      # walk does capture it; nothing excludes it. Restic is simply not what this
      # data is meant to rely on. See NOTES.md.
      pool = "persistent";
      name = "syncthing-data";
      description = "Synced data -- the folders shared with peers";

      snapshots = {
        schedule = "@daily";
        expiry = "7d";
      };
    }
  ];

  devices = devices;

  # ---------------------------------------------------------------------
  # The sync port on the host's LAN address
  # ---------------------------------------------------------------------
  #
  # 22000/tcp and 22000/udp (QUIC) are where Syncthing transfers data. They need
  # a forward because a VPN client routes only 192.168.178.0/24 and
  # 100.64.0.0/10 -- not 10.0.0.0/24 -- so it cannot dial 10.0.0.104 directly.
  # The forward puts the sync port on the host address the peer can already
  # reach.
  #
  # 21027/udp (LAN discovery broadcasts) is deliberately absent: it does not
  # cross a routed forward usefully, and global discovery plus the direct address
  # is enough. The GUI (8384) is NOT forwarded either; it is reached only through
  # Caddy's VPN-gated vhost.
  #
  # This shares 192.168.178.200 with caddy's 80/443, forgejo's 22 and dns' 53.
  # apply.sh reconciles the union of every instance's ports on an address, so
  # declaring these here neither disturbs the others nor depends on their specs.
  networkForward = {
    listenAddress = "192.168.178.200";

    # Derived from devices.eth0 above so the two cannot drift.
    targetAddress = devices.eth0."ipv4.address";

    ports = [
      {
        protocol = "tcp";
        listenPort = 22000;
      }
      {
        protocol = "udp";
        listenPort = 22000;
      }
    ];
  };
}
