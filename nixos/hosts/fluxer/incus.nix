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
      "ipv4.address" = "10.0.0.103";
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
      targetAddress = "10.0.0.103";
      targetPort = 7881;
    }
    {
      # Forward LiveKit UDP 7882 to the instance on incusbr0.
      listenAddress = "192.168.178.200";
      protocol = "udp";
      listenPort = 7882;
      targetAddress = "10.0.0.103";
      targetPort = 7882;
    }
  ];

  renderedSecrets = [
    { format = "raw"; mode = "0400"; file = "fluxer_postgres_password"; dir = "/var/lib/incus-secrets"; source = "/run/secrets/fluxer_postgres_password"; }
    { format = "raw"; mode = "0400"; file = "fluxer_search_api_key"; dir = "/var/lib/incus-secrets"; source = "/run/secrets/fluxer_search_api_key"; }
    { format = "raw"; mode = "0400"; file = "fluxer_s3_secret_access_key"; dir = "/var/lib/incus-secrets"; source = "/run/secrets/fluxer_s3_secret_access_key"; }
    { format = "raw"; mode = "0400"; file = "aws_secret_access_key"; dir = "/var/lib/incus-secrets"; source = "/run/secrets/aws_secret_access_key"; }
    { format = "raw"; mode = "0400"; file = "fluxer_sudo_mode_secret"; dir = "/var/lib/incus-secrets"; source = "/run/secrets/fluxer_sudo_mode_secret"; }
    { format = "raw"; mode = "0400"; file = "fluxer_connection_initiation_secret"; dir = "/var/lib/incus-secrets"; source = "/run/secrets/fluxer_connection_initiation_secret"; }
    { format = "raw"; mode = "0400"; file = "fluxer_profile_pseudonym_secret"; dir = "/var/lib/incus-secrets"; source = "/run/secrets/fluxer_profile_pseudonym_secret"; }
    { format = "raw"; mode = "0400"; file = "fluxer_gateway_rpc_auth_token"; dir = "/var/lib/incus-secrets"; source = "/run/secrets/fluxer_gateway_rpc_auth_token"; }
    { format = "raw"; mode = "0400"; file = "fluxer_media_proxy_secret_key"; dir = "/var/lib/incus-secrets"; source = "/run/secrets/fluxer_media_proxy_secret_key"; }
    { format = "raw"; mode = "0400"; file = "fluxer_media_proxy_upload_relay_secret_base64"; dir = "/var/lib/incus-secrets"; source = "/run/secrets/fluxer_media_proxy_upload_relay_secret_base64"; }
    { format = "raw"; mode = "0400"; file = "fluxer_admin_secret_key_base"; dir = "/var/lib/incus-secrets"; source = "/run/secrets/fluxer_admin_secret_key_base"; }
    { format = "raw"; mode = "0400"; file = "fluxer_admin_oauth_client_secret"; dir = "/var/lib/incus-secrets"; source = "/run/secrets/fluxer_admin_oauth_client_secret"; }
    { format = "raw"; mode = "0400"; file = "fluxer_vapid_public_key"; dir = "/var/lib/incus-secrets"; source = "/run/secrets/fluxer_vapid_public_key"; }
    { format = "raw"; mode = "0400"; file = "fluxer_vapid_private_key"; dir = "/var/lib/incus-secrets"; source = "/run/secrets/fluxer_vapid_private_key"; }
    { format = "raw"; mode = "0400"; file = "livekit_api_secret"; dir = "/var/lib/incus-secrets"; source = "/run/secrets/livekit_api_secret"; }
    { format = "raw"; mode = "0400"; file = "fluxer_erlang_cookie"; dir = "/var/lib/incus-secrets"; source = "/run/secrets/fluxer_erlang_cookie"; }
  ];
}
