# Incus-level definition of the "prowlarr" instance.
#
# See ../syncthing/incus.nix for what belongs in this file versus default.nix.
#
# Prowlarr is the indexer proxy: it talks to *arr and to the indexers, and is
# the only *arr that mounts NO media library at all. Its k3s manifest had a
# single /config PVC and no hostPath shares -- correct, because Prowlarr only
# manages indexer definitions and passes release queries through; it never reads
# or writes the library. That is why media-instance.nix's mountedShares is empty
# for this one (nothing to create on disk).
let
  devices = {
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.109";
    };

    prowlarr-config = {
      type = "disk";
      pool = "persistent";
      source = "prowlarr-config";
      path = "/var/lib/prowlarr";
    };
  };
in
{
  description = "Prowlarr indexer manager";

  autostart = true;

  # Light: Prowlarr is a thin proxy, not a library scanner. 1GiB/1 CPU.
  limits = {
    memory = "1GiB";
    cpu = "1";
  };

  volumes = [
    {
      pool = "persistent";
      name = "prowlarr-config";
      description = "Prowlarr state: indexer definitions, application connections, API key";
      snapshots = {
        schedule = "@daily";
        expiry = "7d";
      };
    }
  ];

  devices = devices;

  # VPN-gated vhost only (prowlarr.sakul-flee.de), no LAN forward.
}