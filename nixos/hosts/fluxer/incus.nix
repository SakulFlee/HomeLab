# Incus-level definition of the "fluxer" instance.
#
# This is a VM (type = vm) because Fluxer self-hosting runs Docker Compose
# inside the guest, matching the official upstream method.
let
  devices = {
    # Bridge on incusbr0, static IP as planned.
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.102";
    };

    # Data volume for Docker data (images, containers, volumes).
    # Block device for VM, mounted by the guest.
    data = {
      type = "disk";
      pool = "persistent";
      source = "fluxer-data";
      # No path for VM block device
    };
  };
in
{
  type = "vm";

  description = "Fluxer chat (self-hosted, Docker Compose)";

  autostart = true;

  limits = {
    memory = "12GiB";
    cpu = "4";
  };

  volumes = [
    {
      pool = "persistent";
      name = "fluxer-data";
      type = "block";
      description = "Fluxer Docker data volumes (Postgres, SeaweedFS state, etc.)";
      snapshots = {
        schedule = "@daily";
        expiry = "7d";
      };
    }
  ];

  devices = devices;

  networkForwards = [
    {
      # Forward LiveKit TCP 7881 to the instance on incusbr0.
      listenAddress = "192.168.178.200";
      protocol = "tcp";
      listenPort = 7881;
      targetAddress = "10.0.0.102";
      targetPort = 7881;
    }
    {
      # Forward LiveKit UDP 7882 to the instance on incusbr0.
      listenAddress = "192.168.178.200";
      protocol = "udp";
      listenPort = 7882;
      targetAddress = "10.0.0.102";
      targetPort = 7882;
    }
  ];
}