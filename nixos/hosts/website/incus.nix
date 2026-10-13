# Incus-level definition of the "website" instance.
#
# See ../cloudflare-ddns/incus.nix for what belongs in this file versus
# default.nix. Briefly: this is the VM, default.nix is the software in it.
#
# A VM, not an LXC, and the reason is the one the repo's rule turns on: the site
# is run as a container, which means a container runtime *inside* the instance.
# An LXC shares the host kernel, so a runtime in there would have to be
# privileged -- handing the guest the host kernel, which is the exact thing
# "LXC unless something needs security.privileged, then VM" exists to refuse.
# A VM brings its own kernel and its own podman, so the one container that runs
# here is as isolated from the host as an OCI container makes it. Same argument
# as ../forgejo-runner/incus.nix (Docker) and ../fluxer/incus.nix (Compose).
let
  devices = {
    # On incusbr0, like every other instance, so Caddy can reach it at
    # 10.0.0.114 in one hop and so egress (the image pull) is NAT'd by
    # incusbr0's ipv4.nat.
    #
    # The address is NOT configured here. Incus can hand a *container* a static
    # address; it cannot configure a guest's network, so default.nix sets
    # 10.0.0.114 itself by matching this NIC's MAC -- which is why hwaddr is
    # pinned rather than left to Incus. An Incus-assigned MAC can change on a
    # re-create, and a networkd unit matching nothing leaves the VM booted,
    # unrouted and silent. Must match bridgeMac in default.nix.
    #
    # No `path` anywhere below: a VM gets raw block devices, not bind mounts.
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      hwaddr = "00:16:3e:00:00:13";
    };
  };
in
{
  # The single switch that changes how this instance is built and created:
  # qcow2 rather than squashfs+metadata, `incus create -t vm`, block volume
  # content type, and no `path` on disk devices. See incus/README.md.
  type = "vm";

  description = "Personal website (nginx static site, run as an OCI container)";

  # Start on boot, and come back up after apply.sh recreates it. An instance
  # that was deliberately stopped stays stopped; see apply.sh.
  #
  # This is not opt-out-tempting the way it is for the media stack: the site is
  # the public front page, so there is no reading of "it was off" that is not a
  # fault.
  autostart = true;

  # 1GiB / 2 CPU. The site itself is a static Astro build served by nginx with
  # four workers, which is a few tens of MiB; the rest is the NixOS closure,
  # podman and its image store.
  #
  # Small on purpose. The k3s deployment this replaces declared no requests and
  # no limits at all, so it borrowed whatever the node had spare -- which is a
  # number nobody wrote down and cannot now recover. This is a deliberate,
  # written-down cap rather than a guess, and it is sized to be obviously
  # generous rather than tight, so raising it later is a decision rather than a
  # rescue.
  limits = {
    memory = "1GiB";
    cpu = "2";
  };

  # No volumes, and deliberately no snapshot policy either.
  #
  # Nothing in this instance is authoritative state: the site is a build
  # artefact that lives in the image, podman's copy is re-pullable by definition
  # (and is re-pulled anyway -- `pull = "always"`, see default.nix), and there
  # is no database and no writable application directory. So a re-create loses
  # nothing, there is nothing to back up, and rolling a stateless
  # static site back to a previous snapshot would be meaningless.
  #
  # The default 10 GiB VM root disk is deliberately left alone: the closure plus
  # one pulled image is a small fraction of it, and incus-virtual-machine.nix
  # sets autoResize/growPartition so the guest claims whatever Incus actually
  # grants. See rootDiskSize in ../forgejo-runner/incus.nix for the case where
  # the default genuinely is not enough.

  # No renderedSecrets and no secretConsumers. The image is public: it pulls
  # from forgejo.sakul-flee.de anonymously, verified before this was written --
  # the registry 401s without a token, but issues one for an anonymous request
  # and then serves the manifest, so `podman pull` needs no credentials at all.
  # Minting a read:package token for a public package would have been a
  # credential with no privilege to do anything and one more thing to rotate.

  # No networkForward. This is a public site, but it does not need a port on the
  # host's LAN address: the incus network forward on 192.168.178.200 is already
  # carrying :80 and :443 for Caddy, and Caddy terminates TLS for both names and
  # proxies over the bridge to 10.0.0.114:80. Nothing on the LAN needs to reach
  # this instance directly, and a forward would be a second, ungated way in.

  devices = devices;
}