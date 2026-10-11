# NixOS inside the "website" VM.
#
# What is actually running: the container the k3s deployment ran, unchanged.
# The image is `forgejo.sakul-flee.de/sakulflee/website:latest` -- an Astro
# static build served by nginx, listening on 80 and nothing else. The point of
# keeping it a container is that nothing about the site changes when it moves:
# same image, same tag, same `pull: always` semantics the Deployment had, and
# the upstream repository stays the only place the site is built.
#
# It runs through NixOS's `virtualisation.oci-containers`, which is podman
# wrapped in a generated systemd unit. That is deliberately the smallest thing
# that can run one container -- no compose file, no hand-written `docker run`,
# no daemon to reconcile separately. See incus.nix for why this is a VM.
#
# See incus.nix for the Incus half (limits, devices) and README.md for the
# migration notes, the cutover and how to roll it back.
{ config, lib, pkgs, ... }:

let
  # The VM's address on incusbr0. Set in the guest, not through Incus: Incus
  # can hand a *container* a static address, but a guest configures its own
  # network. Matched on the NIC's MAC, which incus.nix pins, so it survives a
  # re-create -- an Incus-assigned MAC would not.
  bridgeAddress = "10.0.0.114";

  # Must match hwaddr in incus.nix.
  bridgeMac = "00:16:3e:00:00:13";

  # The container, verbatim from apps/website/deployment.yaml. Pinned to `:latest`
  # on purpose, because that is what the k3s deployment pulled: the tag is the
  # release channel, and Forgejo Actions republishes it. `pull = "always"` below
  # is the same promise `imagePullPolicy: Always` made -- the running container
  # is never older than the registry's idea of `latest`, even after a re-create.
  image = "forgejo.sakul-flee.de/sakulflee/website:latest";
in
{
  networking.hostName = "website";

  # ---------------------------------------------------------------------
  # Addressing
  # ---------------------------------------------------------------------
  #
  # networkd rather than networking.interfaces, for the same two reasons as
  # forgejo-runner: nixpkgs has no way to match on a MAC through
  # networking.interfaces, and the virtio NIC's kernel name (enp1s0 and
  # friends) is not a safe thing to key a config on. Matching on the pinned MAC
  # is deterministic.
  networking.useNetworkd = true;

  systemd.network.networks."10-incus" = {
    matchConfig.MACAddress = bridgeMac;
    networkConfig = {
      Address = [ "${bridgeAddress}/24" ];

      # incusbr0's gateway, which is the host. Egress -- the image pull -- is
      # NAT'd by incusbr0's ipv4.nat.
      Gateway = "10.0.0.1";

      # The router, which is what the host itself resolves through. Not the
      # host's CoreDNS (192.168.178.200): that answers only for the VPN-only
      # names in ../dns/default.nix, and everything else falls through upstream
      # anyway, so pointing at it would buy a hop and nothing else.
      #
      # This has to resolve forgejo.sakul-flee.de for the pull to work at all.
      # It is not in the split-horizon zone, so it resolves publicly to the WAN
      # address and the pull comes back in through the router's NAT loopback --
      # the same path every k3s pull of this image took, from a node on the same
      # network.
      DNS = [ "192.168.178.1" ];
    };
  };

  # No guest firewall. The same conclusion forgejo-runner reached, for the same
  # reason: the host and Incus are the boundary. Nothing from the LAN can reach
  # this instance -- there is no networkForward, so no port on 192.168.178.200
  # is aimed here -- and the only inbound traffic is Caddy on the bridge.
  networking.firewall.enable = false;

  # On for a VM and off for a container, which is the distinction the flake's
  # mkInstance draws: a guest has a real network and should not be reachable
  # only through `incus exec`. Nothing forwards 22, so this is bridge-local --
  # the host and the other instances -- and it is what you want when the thing
  # you need to debug is podman.
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
    };
  };

  # ---------------------------------------------------------------------
  # The website container
  # ---------------------------------------------------------------------
  #
  # One container, run by podman as the generated `podman-website.service`.
  #
  # `virtualisation.oci-containers` with no `backend` set resolves to podman,
  # because mkInstance pins system.stateVersion = "25.11" and the module's
  # default is "podman" for anything at or above 22.05. Setting it explicitly
  # would be a second thing to keep true.
  #
  # No `login`. The package is public: `forgejo.sakul-flee.de` answers /v2/token
  # for an anonymous request and then serves the manifest, so the pull needs no
  # credential. Verified before this was written rather than assumed -- the
  # registry does 401 a bare manifest request, which is the Docker Registry
  # auth challenge and not a denial, and following it anonymously succeeds.
  virtualisation.oci-containers.containers.website = {
    image = image;

    # The direct translation of `imagePullPolicy: Always`.
    #
    # The default is "missing", which would be the one behaviour change in this
    # migration: it would let the running container fall arbitrarily far behind
    # the registry, and a re-created VM would come up on whatever podman's image
    # store happened to hold. "always" re-pulls on every start, so a reboot and
    # a re-create both cost exactly one pull.
    pull = "always";

    # Published on every interface in the guest, which is what Caddy needs: it
    # dials 10.0.0.114:80 across the bridge. The guest firewall is off and
    # incusbr0 is behind the host's NAT with no route in from the LAN, so this
    # is reachable from the host and the other instances and nothing else.
    ports = [ "80:80" ];

    # Default true, stated because "the site is down" is not a state anyone
    # wants to have to reason about at boot.
    autoStart = true;
  };

  # curl, for the verification in README.md and for debugging the proxy path
  # without a second round trip through the Incus API.
  environment.systemPackages = [ pkgs.curl ];

  # lxc-instance-common.nix sets root's initial password to the empty string,
  # which the flake's mkForce already locks; restated here to match fluxer and
  # to keep the file self-contained if it is ever read on its own. `incus exec`
  # goes through the API and does not care.
  users.users.root.initialHashedPassword = lib.mkForce "!";

  system.stateVersion = "25.11";
}