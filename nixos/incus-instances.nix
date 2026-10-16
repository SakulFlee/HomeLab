# Every Incus instance this host manages, and the only place that knows the
# list of names.
#
# Two consumers, deliberately:
#
#   * nixos/flake.nix reads it to expose `incusInstances.<name>` as a flake
#     output, so incus/apply.sh can ask the flake what an instance should look
#     like (nix eval --json .#incusInstances.<name>) without parsing Nix in
#     shell.
#   * nixos/hosts/homelab/services/incus-instances.nix reads it to generate one
#     systemd service and one systemd.paths unit per instance.
#
# Because both derive from this one file, an instance cannot exist in one place
# and not the other. Adding an entry here is the whole job; there is no second
# list to keep in sync.
#
# The value of each entry is the instance's *Incus-level* definition -- the
# things the container config cannot express: which image, how much CPU and
# memory, which storage volumes, which extra devices. See
# nixos/hosts/<name>/incus.nix. The OS config lives beside it in
# nixos/hosts/<name>/default.nix.
{
  caddy = import ./hosts/caddy/incus.nix;
  dns = import ./hosts/dns/incus.nix;
  forgejo = import ./hosts/forgejo/incus.nix;
  # A VM. Its incus.nix sets `type = "vm"`, which is what switches the image
  # build (qcow2 rather than squashfs+metadata), the create call (`-t vm`), the
  # volume type (block, not filesystem) and the disk devices (no `path`).
  # The forgejo-runner is a VM for the same reason wireguard is: it runs
  # Docker inside the guest, which an LXC could only do privileged.
  wireguard = import ./hosts/wireguard/incus.nix;
  forgejo-runner = import ./hosts/forgejo-runner/incus.nix;
  fluxer = import ./hosts/fluxer/incus.nix;
  # An LXC, not a VM: Syncthing is a single static Go binary and needs no kernel
  # of its own. It is the replication hub other instances' volumes are attached
  # to read-only; see hosts/syncthing/NOTES.md for that standard.
  syncthing = import ./hosts/syncthing/incus.nix;
  # Paperless, on the `default` project so its media volume can be mounted by
  # the Syncthing hub (see hosts/syncthing/NOTES.md and replicated-volumes.nix).
  # VPN-only, behind Caddy.
  paperless = import ./hosts/paperless/incus.nix;

  # Minecraft. A container, and the first instance whose public entry point is
  # not HTTP: the Java protocol is a raw TCP stream, so it gets an
  # `incus network forward` for 25565/tcp rather than a Caddy vhost. Also the
  # second producer in the Syncthing replication scheme, contributing
  # minecraft-backups (see nixos/replicated-volumes.nix) -- archives only, never
  # the live world. See hosts/minecraft/README.md.
  minecraft = import ./hosts/minecraft/incus.nix;

  # Hytale. Same shape as minecraft -- a JVM in a container, and a network
  # forward rather than a Caddy vhost because QUIC has no hostname in it -- and
  # the third producer in the Syncthing replication scheme, contributing
  # hytale-backups (see nixos/replicated-volumes.nix). Archives only, never the
  # live universe. See hosts/hytale/README.md.
  hytale = import ./hosts/hytale/incus.nix;

  # First of the media stack. Read-only consumer of the library: four NAS
  # shares bind-mounted ro (Incus 7.0.1 cannot make a CIFS bind writable from
  # an unprivileged LXC -- measured, see hosts/jellyfin/incus.nix) and the iGPU
  # passed through for VAAPI. Config and cache are pool volumes.
  jellyfin = import ./hosts/jellyfin/incus.nix;

  # The *ARR family and QUI. Same shape as jellyfin: unprivileged, shares
  # bind-mounted from the bindfs mirror at /mnt/nas-mapped (which is what makes
  # them writable), config on a `persistent` pool volume.
  #
  # Read/write split, which is the one thing that differs between them and is
  # worth stating here rather than per file: the library shares are mounted
  # read-only and only the qBittorrent staging share is writable. These apps
  # hand releases to qBittorrent; they do not edit media in place.
  sonarr = import ./hosts/sonarr/incus.nix;
  radarr = import ./hosts/radarr/incus.nix;
  prowlarr = import ./hosts/prowlarr/incus.nix;
  qui = import ./hosts/qui/incus.nix;

  # qBittorrent, all traffic through PIA. The security-critical one: every
  # packet it sends is confined by uid-based routing to the OpenVPN tunnel,
  # with an `unreachable` rule as the kill-switch -- see the file header in
  # hosts/qbittorrent/default.nix before changing anything there.
  qbittorrent = import ./hosts/qbittorrent/incus.nix;

  # Cloudflare DynDNS. A container: the client is a single static Go binary
  # with no kernel or device requirements, and it only dials out. Stateless --
  # the records it manages live in Cloudflare, not on its disk. Replaces the
  # k3s CronJob in apps/cloudflare-ddns/; see hosts/cloudflare-ddns/default.nix.
  cloudflare-ddns = import ./hosts/cloudflare-ddns/incus.nix;

  # Renovate. A container: every language manager it drives is a userspace
  # toolchain it execs directly, so there is no kernel of its own, no /dev
  # passthrough and no Docker daemon that would have forced a privileged guest.
  # Stateless -- branches and PRs live in Forgejo -- and driven by an adaptive
  # scheduler rather than a timer; see hosts/renovate/default.nix. Replaces the
  # k3s CronJob in apps/renovate/.
  renovate = import ./hosts/renovate/incus.nix;

  # The public website, and the only VM in the repository that exists purely to
  # run a container: the site is served from
  # forgejo.sakul-flee.de/sakulflee/website:latest, so it needs a container
  # runtime inside the guest, which is the same "privileged or VM" fork the
  # runner and fluxer take. See hosts/website/incus.nix.
  website = import ./hosts/website/incus.nix;

  # Hermes (NousResearch hermes-agent), replacing the k3s deployment that
  # b9b3b184 rolled down. A container: the gateway, the dashboard and the
  # managed llama-server are all userspace, and the iGPU comes in through a
  # bare `gpu` device (vulkan compute, sharing the card with jellyfin's VAAPI).
  # Local models are served by Hermes's own llama.cpp runtime rather than an
  # Ollama instance -- see hosts/hermes/default.nix.
  hermes = import ./hosts/hermes/incus.nix;

  # OmniRoute (diegosouzapw/OmniRoute), the AI gateway: a unified /v1 API in
  # front of many providers. A container, like hermes: a Node.js process, no
  # kernel of its own and no device to pass through. Packaged from the npm
  # release in hosts/omniroute/package.nix. VPN-only behind Caddy, and the
  # only instance whose guest firewall is ON -- it listens on a port that can
  # spend money. See hosts/omniroute/NOTES.md.
  omniroute = import ./hosts/omniroute/incus.nix;
}
