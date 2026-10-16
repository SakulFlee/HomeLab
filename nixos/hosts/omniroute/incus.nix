# Incus-level definition of the "omniroute" instance.
#
# See ../renovate/incus.nix for the closest sibling in shape (a userspace
# daemon on its own address, secrets rendered by the host); this file is the
# container, not the software -- default.nix holds that.
#
# A container, not a VM: OmniRoute is a Node.js process. No kernel of its own
# to want, no /dev passthrough, no container runtime inside the guest that
# would have forced a privileged guest (the forgejo-runner/fluxer/website
# fork). The one kernel-adjacent thing it might use -- btrfs CoW for its
# internal backups and migrations -- works on the volume without any device
# being passed through, because the snapshot primitive is the host's.
let
  devices = {
    # Overrides the 'default' profile's eth0 with a fixed address. Verified
    # free before assignment: .53-.54 and .100-.117 are taken (.117 is hermes,
    # do not reuse it), so .118 is the first free address on incusbr0.
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.118";
    };

    omniroute-data = {
      type = "disk";
      pool = "persistent";
      source = "omniroute-data";
      path = "/var/lib/omniroute";
    };

    # The rendered secrets land here rather than on the rootfs (the
    # cloudflare-ddns/renovate shape) so a root snapshot of the instance
    # cannot accidentally contain them, and so the volume can be inspected
    # without touching the app's state. Same path and same reasoning as
    # caddy's secrets volume.
    omniroute-secrets = {
      type = "disk";
      pool = "persistent";
      source = "omniroute-secrets";
      path = "/var/lib/incus-secrets";
    };
  };
in
{
  description = "OmniRoute AI gateway (diegosouzapw/OmniRoute)";

  # Start on boot, and come back after apply.sh recreates the instance. A
  # gateway that only runs when someone remembers to start it is a gateway
  # that is silently down.
  autostart = true;

  # 4GiB / 2 CPU. Upstream's documented minimum for a small deployment is
  # 2 vCPU / 2 GiB; this is headroom rather than a measured peak, because
  # there is no measured peak yet -- the first thing worth doing after deploy
  # is watching `incus info omniroute` under real traffic and tightening.
  # The ceiling matters beyond comfort: this is the same class of service as
  # hermes, and an OOM here takes down the gateway, not the node.
  limits = {
    memory = "4GiB";
    cpu = "2";
  };

  devices = devices;

  volumes = [
    {
      pool = "persistent";
      name = "omniroute-data";
      description = "DATA_DIR: SQLite database, encrypted provider credentials, internal backups";

      # @hourly/7d, the repository's standard for a state volume (syncthing,
      # paperless, hermes-state). Btrfs CoW, which is also what upstream's
      # migration-safety guidance asks for: their internal db_backups are
      # content-addressed inside DATA_DIR, and these Incus snapshots are the
      # outer rollback layer. Provider credentials in here are ciphertext --
      # the keys come from the environment, not the volume -- so a snapshot
      # is safe to keep.
      snapshots = {
        schedule = "@hourly";
        expiry = "7d";
      };
    }
    {
      # No `snapshots`, same reasoning as hermes-secrets and caddy-secrets: a
      # copy of a live secret is a liability, and the files are rewritten from
      # the host's decrypted values on every apply.sh run anyway.
      pool = "persistent";
      name = "omniroute-secrets";
      description = "Host-rendered EnvironmentFiles; the only secrets this instance ever sees";
    }
  ];

  # The four values OmniRoute refuses to run without, in the exact form the
  # app reads them. Declared on the host (nixos/modules/sops.nix) so the
  # instance gets rendered bytes and no decryption capability -- the
  # caddy/renovate/hermes pattern, for the same reason as all three: a root
  # process here cannot read the restic password, the Forgejo secrets or the
  # VPN credentials out of the host's secrets.yaml.
  #
  # format=env: each file is one KEY=value line, which is exactly what
  # systemd's EnvironmentFile= wants and what this format produces. Values
  # generated on the host at first deploy (see NOTES.md); they are the four
  # upstream documents as required, and nothing else -- MACHINE_ID_SALT stays
  # at its default because a secret nobody needs to rotate buys nothing.
  renderedSecrets = [
    {
      format = "env";
      file = "omniroute-jwt-secret-env";
      env = "JWT_SECRET";
      source = "/run/secrets/omniroute_jwt_secret";
    }
    {
      format = "env";
      file = "omniroute-api-key-secret-env";
      env = "API_KEY_SECRET";
      source = "/run/secrets/omniroute_api_key_secret";
    }
    {
      format = "env";
      file = "omniroute-initial-password-env";
      env = "INITIAL_PASSWORD";
      source = "/run/secrets/omniroute_initial_password";
    }
    {
      format = "env";
      file = "omniroute-storage-encryption-key-env";
      env = "STORAGE_ENCRYPTION_KEY";
      source = "/run/secrets/omniroute_storage_encryption_key";
    }
  ];

  # The unit that reads the files above. Not optional in practice, same as
  # every other rendered-secret instance: on a first deploy omniroute.service
  # cannot start at all, because systemd fails a unit outright when an
  # EnvironmentFile= source is missing rather than starting it without the
  # variables. apply.sh writes the files and then restarts this unit --
  # unconditionally, after reset-failed, because a try-restart on a unit that
  # has never started is a no-op and the secrets would never be picked up.
  secretConsumers = [ "omniroute.service" ];

  # No networkForward. The only published path is Caddy's VPN-gated vhost
  # (omniroute.sakul-flee.de -> 10.0.0.118:20128 on the bridge); the guest
  # firewall in default.nix additionally confines 20128 to bridge-arrived
  # traffic, so the host and the other LXCs can reach the API directly and
  # nothing else can.
}
