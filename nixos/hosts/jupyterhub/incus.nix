# Incus-level definition of the "jupyterhub" instance.
#
# See ../omniroute/incus.nix for the closest sibling in shape (a userspace
# daemon on its own bridge address, a host-rendered secret, VPN-only behind
# Caddy); this file is the container, not the software -- default.nix holds
# that.
#
# A container, not a VM: JupyterHub, its proxy, systemdspawner and every
# single-user server are Python processes. Nothing here needs a kernel of its
# own -- not even the GPU, which incus passes through by device rather than by
# giving the guest a driver (the same reasoning as jellyfin's VAAPI and hermes's
# vulkan). A VM would only be forced by a container runtime inside a notebook,
# which is not a requirement.
let
  devices = {
    # Overrides the 'default' profile's eth0 with a fixed address, the same
    # shape every other instance uses. Verified free before assignment: .100
    # through .118 are taken (omniroute is .118), so .119 is the next free
    # address on incusbr0.
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.119";
    };

    # -------------------------------------------------------------------------
    # The iGPU.
    # -------------------------------------------------------------------------
    #
    # A BARE gpu device, no uid/gid/mode and no idmap -- the shape jellyfin and
    # hermes measured on this host (Incus 7.0.1): renderD128 arrives as 0666,
    # so a kernel can open it as any user and no group mapping is needed.
    #
    # Passed rather than assumed: nothing in the repository's default kernel
    # uses it yet (see default.nix), but adding it now costs one device and
    # means a GPU kernel is a NixOS edit rather than a container recreate.
    # RADV needs only the render node; /dev/kfd is a ROCm surface and is
    # deliberately NOT passed, for the same reason hermes does not -- handing
    # over a compute node this instance cannot open yet has no upside.
    #
    # Coexistence with jellyfin (VAAPI) and hermes (vulkan) is measured, not
    # assumed: all three open the same card, and VAAPI/state-decode and vulkan
    # compute do not conflict. The real contention is the shared 8 GiB of
    # iGPU memory, which the limits below turn into a bounded failure.
    gpu = {
      type = "gpu";
    };

    # -------------------------------------------------------------------------
    # Data-bearing volumes on `persistent`. Each is a mount the container's
    # rootfs does not carry, because a recreate replaces the rootfs -- and
    # recreates happen on every image rebuild. The notes on each entry say what
    # the snapshot is the rollback FOR; the same @hourly/7d policy as every
    # other state volume in the repository (syncthing, paperless, hermes).
    # -------------------------------------------------------------------------

    # The hub's own state: jupyterhub.sqlite (users, tokens, server records)
    # and jupyterhub_cookie_secret. Root-owned; the tmpfiles rule in
    # default.nix guarantees the mountpoint.
    jupyterhub-data = {
      type = "disk";
      pool = "persistent";
      source = "jupyterhub-data";
      path = "/var/lib/jupyterhub";
    };

    # User home directories, mounted at /home. This is the irreplaceable half:
    # a recreate that loses the hub database costs a re-login, but a recreate
    # that loses a notebook costs the work in it.
    jupyterhub-home = {
      type = "disk";
      pool = "persistent";
      source = "jupyterhub-home";
      path = "/home";
    };

    # Host-rendered secrets land here rather than on the rootfs, so a root
    # snapshot of the instance cannot accidentally contain them -- same path and
    # same reasoning as caddy's and omniroute's secrets volume.
    jupyterhub-secrets = {
      type = "disk";
      pool = "persistent";
      source = "jupyterhub-secrets";
      path = "/var/lib/incus-secrets";
    };
  };
in
{
  description = "JupyterHub multi-user notebook platform (Forgejo OAuth)";

  # Start on boot, and come back after apply.sh recreates the instance. A
  # notebook platform that only runs when someone remembers to start it is
  # silently down.
  autostart = true;

  # 4 vCPU / 8 GiB. There is no measured peak yet -- unlike hermes there is no
  # k3s deployment to have measured -- so this is headroom rather than a fit:
  # the hub is small, but every connected user gets their own kernel, and a
  # data-science kernel loading a frame is memory-hungry in bursts. Adjust
  # live with `incus config set jupyterhub limits.memory ...` once real load
  # says what it should be. The ceiling matters: an unbounded kernel would OOM
  # the host, while this contains it to a killed notebook.
  limits = {
    memory = "8GiB";
    cpu = "4";
  };

  devices = devices;

  volumes = [
    {
      pool = "persistent";
      name = "jupyterhub-data";
      description = "Hub state: jupyterhub.sqlite, jupyterhub_cookie_secret";

      # Snapshots are the rollback for a bad upgrade or an accidental
      # `jupyterhub` DB migration, not for the notebooks -- those are on
      # jupyterhub-home. Losing this file only costs a re-login.
      snapshots = {
        schedule = "@hourly";
        expiry = "7d";
      };
    }
    {
      pool = "persistent";
      name = "jupyterhub-home";
      description = "User home directories: notebooks, data, everything authored";

      # The whole point of the volume. A resume-from-snapshot recovers work a
      # user deleted or a kernel overwrote; it is the only copy of anything a
      # person wrote here.
      snapshots = {
        schedule = "@hourly";
        expiry = "7d";
      };
    }
    {
      # No `snapshots`, same reasoning as hermes-secrets and caddy-secrets: a
      # copy of a live credential is a liability, and the file is rewritten
      # from the host's decrypted value on every apply.sh run anyway.
      pool = "persistent";
      name = "jupyterhub-secrets";
      description = "Host-rendered EnvironmentFiles; the only secret this instance ever sees";
    }
  ];

  # The Forgejo OAuth client secret, as one KEY=value line -- which is exactly
  # what format=env produces and what the unit's EnvironmentFile= wants. The
  # hub's config reads it as os.environ["JUPYTERHUB_FORGEJO_CLIENT_SECRET"].
  #
  # Declared on the host (nixos/modules/sops.nix) so the instance gets rendered
  # bytes and no decryption capability -- the caddy/renovate/hermes/omniroute
  # pattern, for the same reason: a root process in here cannot read the restic
  # password, the Forgejo secrets or the VPN credentials out of the host's
  # secrets.yaml.
  renderedSecrets = [
    {
      format = "env";
      file = "jupyterhub-forgejo-oauth-env";
      env = "JUPYTERHUB_FORGEJO_CLIENT_SECRET";
      source = "/run/secrets/jupyterhub_forgejo_client_secret";
    }
  ];

  # The unit that reads the file above. Not optional in practice: on a first
  # deploy jupyterhub.service cannot start at all, because the config reads the
  # environment variable unconditionally and systemd refuses a missing
  # EnvironmentFile= source rather than starting without it. apply.sh writes
  # the file and then restarts this unit -- unconditionally, after
  # reset-failed, because a try-restart on a unit that never started is a
  # no-op and the secret would never be picked up.
  secretConsumers = [ "jupyterhub.service" ];

  # No networkForward. The only published path is Caddy's VPN-gated vhost
  # (jupyter.sakul-flee.de -> 10.0.0.119:8000 on the bridge); the guest
  # firewall in default.nix confines 8000 to bridge-arrived traffic, so the
  # host, the other LXCs and Caddy can reach the hub and the LAN has no route
  # to it at all.
}
