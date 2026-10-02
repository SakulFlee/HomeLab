# Incus-level definition of the "caddy" instance.
#
# This file describes the container, not the software inside it. Anything NixOS
# can configure belongs in default.nix, which is what gets built into the image;
# what is left is the handful of facts only Incus knows: how much CPU and RAM,
# where its writable data lives, and which network device it gets.
#
# Read at build time by incus/apply.sh through the `incusInstances` flake
# output. See ../../../incus-instances.nix for the list.
let
  devices = {
    # Overrides the 'default' profile's eth0 with a fixed address. The profile
    # supplies type/name/network; only the address is added, so the instance
    # still gets a veth on incusbr0 and NAT egress.
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.100";
    };

    caddy-data = {
      type = "disk";
      pool = "backup";
      source = "caddy-data";
      path = "/var/lib/caddy";
    };

    caddy-secrets = {
      type = "disk";
      pool = "persistent";
      source = "caddy-secrets";
      path = "/var/lib/incus-secrets";
    };
  };
in
{
  description = "Reverse proxy for everything in the homelab";

  # Start on boot, and bring it back up after apply.sh recreates it. An
  # instance that was deliberately stopped stays stopped; see apply.sh.
  autostart = true;
  #
  # This also drives Incus's own `boot.autostart`, which apply.sh reconciles from
  # here. The two are different settings that share a name: the reconciler reads
  # this to decide whether to start the instance *now*, and Incus reads its own to
  # decide whether to start it after the daemon comes up. Before that was wired,
  # every instance reconciled correctly and still failed to come back after a host
  # reboot, because Incus defaults boot.autostart to false.
  #
  # Verified by control rather than by inspection, since "it came back" proves
  # nothing on its own -- something else could be starting them. With
  # boot.autostart=false and the instance stopped, a daemon restart left it
  # STOPPED; with true, forgejo and this VM both came back. The VM's uptime
  # confirmed a real boot rather than surviving the restart, which containers do.

  # Caddy is not a memory hog, but it terminates TLS for every request on the
  # LAN and holds buffers for large uploads. 512MiB is headroom, not a cap
  # anyone has hit.
  limits = {
    memory = "512MiB";
    cpu = "2";
  };

  # ACME certificates and the on-disk config Caddy writes at runtime. On the
  # restic'd 'backup' pool because losing these means re-issuing certificates
  # from Let's Encrypt, and running into the rate limit is a genuine outage.
  # The Caddyfile itself is in the flake and is not stored here.
  volumes = [
    {
      pool = "backup";
      name = "caddy-data";
      description = "Caddy ACME certificates and runtime state";
    }
    {
      # Environment files the host renders in from its own sops secrets. Not
      # restic'd: a backed-up copy of a live API token is a liability, and
      # nothing here is irreplaceable -- apply.sh rewrites it from the host's
      # decrypted secret on every run.
      pool = "persistent";
      name = "caddy-secrets";
      description = "Host-rendered EnvironmentFiles; the only secret this instance ever sees";
    }
  ];

  # Files the host renders into this instance, from secrets the host itself
  # decrypts. incus/apply.sh reads `source` on the host and writes
  # `ENV_NAME=<value>` into `file` inside the instance.
  #
  # This is the whole of the instance's access to any secret, and it is
  # deliberately not a key. An earlier version bind-mounted the host's SSH
  # identity key and ran sops-nix inside the container, which worked and was the
  # wrong shape: it let a root process here decrypt every value in the host's
  # secrets.yaml, not just the Cloudflare token. Handing over a rendered value
  # means this instance has no decryption capability at all -- it cannot reach
  # the restic password, the Forgejo JWT secret, or the VPN credentials even if
  # it wants to.
  #
  # The price is that the token is at rest in this volume. That is the trade for
  # removing a whole-file decryption capability, and the volume is on the
  # not-restic'd pool so no copy leaves the box.
  renderedSecrets = [
    {
      file = "caddy-env";
      env = "CF_API_TOKEN";
      # Materialised by the host's sops.secrets.cloudflare_api_token.
      source = "/run/secrets/cloudflare_api_token";
    }

    # format = "raw": the bytes are written through unchanged, because a PEM
    # cannot be an EnvironmentFile line. `env` would produce
    # INCS_CLIENT_KEY=-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n and Caddy would
    # then be handed one enormous malformed variable instead of a key file.
    #
    # mode/group, not the 0400 root-only default, and this is load-bearing rather
    # than tidier. caddy.service runs as User=caddy (NixOS's caddy module drops
    # privileges), and it reads tls_client_auth files itself -- unlike
    # EnvironmentFile, which systemd opens as root before dropping them. At 0400
    # root:root Caddy cannot read its own key, exits, and every hostname goes
    # down while apply.sh cheerfully reports success.
    #
    # 0440 root:caddy rather than 0444: the private key stays unreadable by
    # everything except root and the one user that needs it.
    {
      format = "raw";
      file = "incus-client.crt";
      source = "/run/secrets/incus_client_cert";
      mode = "0440";
      group = "caddy";
    }
    {
      format = "raw";
      file = "incus-client.key";
      source = "/run/secrets/incus_client_key";
      mode = "0440";
      group = "caddy";
    }
  ];

  # Units inside this instance that read a rendered file, and that
  # apply.sh restarts when the file's contents change.
  #
  # Not optional in practice: caddy.service has EnvironmentFile pointing at
  # caddy-env, so on a first deploy it fails to start because the file is not
  # there yet, and only comes up once apply.sh has written it and restarted the
  # unit. `try-restart` would be a no-op on a unit that never started, so
  # apply.sh uses an unconditional `restart`.
  secretConsumers = [ "caddy.service" ];

  # Trust this certificate with Incus, so the incus.sakul-flee.de vhost can
  # authenticate to the API. apply.sh adds it only when absent, and replaces a
  # same-named entry holding a different certificate -- which is what a rotation
  # looks like.
  #
  # `certificate` is the host-side path, the same one rendered above into the
  # instance. It is read host-side rather than read back out of the container so
  # that this does not depend on the instance being reachable, and so the
  # reconciler never has to move a private key in or out of a container.
  #
  # Deliberately NOT `--projects default` / `--restricted`. It looks like least
  # privilege, but storage pools and networks are not per-project, so a
  # restricted certificate makes exactly those pages of the UI fail. The VPN gate
  # is the real control here and the certificate is the second layer, not a
  # substitute for either.
  incusTrust = {
    name = "caddy-proxy";
    certificate = "/run/secrets/incus_client_cert";
  };

  # ---------------------------------------------------------------------
  # The host's public entry points
  # ---------------------------------------------------------------------
  #
  # This is the cutover. Until it exists, Traefik inside k3s serves :80 and
  # :443 on the host and Caddy is a passenger; once it exists, every hostname
  # terminates TLS at Caddy and is handed back to Traefik over the bridge.
  #
  # Incus implements a forward as an nftables DNAT rule, not a socket bind, so
  # it coexists with Traefik's 0.0.0.0:80 listener. Packets aimed at
  # listenAddress are rewritten before socket lookup; packets aimed anywhere
  # else on the same port are not. That asymmetry is the whole reason the
  # still-traefik catch-all in default.nix is loop-free -- it dials 10.0.0.1,
  # which this rule does not match.
  #
  # Rollback, effective immediately, because Traefik's listener is never
  # released while the rule exists:
  #
  #   incus network forward delete incusbr0 192.168.178.200
  networkForward = {
    # The host's LAN address. Must match the host's own address; nothing
    # validates that, and a forward listening somewhere nothing answers is the
    # quietest possible failure.
    listenAddress = "192.168.178.200";

    # Derived from devices.eth0 above so the two cannot drift.
    targetAddress = devices.eth0."ipv4.address";

    # One entry per port, not "80,443" in a single entry: `incus network
    # forward port add` treats a comma list as one grouped entry, which cannot
    # be removed one port at a time later.
    #
    # The raw TCP/UDP services (minecraft 25565, hytale 5520/udp, livekit
    # 7881/7882, matrix 8448) are deliberately absent. An L7 proxy cannot
    # carry them; they get their own forward entries here when they move.
    ports = [
      {
        protocol = "tcp";
        listenPort = 80;
      }
      {
        protocol = "tcp";
        listenPort = 443;
      }
    ];
  };

  devices = devices;
}
