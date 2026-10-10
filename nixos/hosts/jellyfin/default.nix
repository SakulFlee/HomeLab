# NixOS system for the Incus instance "jellyfin".
#
# Jellyfin with VAAPI hardware transcoding on the host iGPU, reading the media
# library from the NAS bind-mounts declared in ./incus.nix.
#
# The package choice that shapes this file: the k3s deployment ran
# lscr.io/linuxserver/jellyfin (a Debian container with its own uid/gid
# handling). This runs the nixpkgs services.jellyfin instead, like every other
# instance in this repo runs the nixpkgs services.* module for its app. That
# keeps the whole Incus stack uniform and declarative, and drops the linuxserver
# PUID/PGID indirection: a NixOS service has real users and groups rather than
# a numeric pair in environment variables.
#
# The consequence is worth stating plainly: this is NOT a data migration. The
# k3s Jellyfin watched /config (library database, users, watch history) on a PVC.
# Per the port decision no data is imported from k3s, so /var/lib/jellyfin
# starts empty and this is a clean Jellyfin that re-indexes the library from the
# NAS paths.
{ config, lib, pkgs, ... }:
{
  imports = [ ../../modules/media-instance.nix ];

  networking.hostName = "jellyfin";

  # curl, for reaching the app at verification time and for the healthcheck.
  # intel-media-driver and libva-utils are added in their own block below; they
  # are listed there with the reasoning, not here.
  #
  # The four library shares Jellyfin reads, mounted read-only. Matches the four
  # ro bind devices in ./incus.nix; qBittorrent is deliberately absent. This
  # records surface only -- media-instance.nix creates nothing for these paths,
  # because they are read-only CIFS mounts (see its header).
  mediaInstance.mountedShares = [
    "Movies"
    "Shows"
    "NSFW"
    "personal_folder"
  ];

  # ---------------------------------------------------------------------------
  # Jellyfin
  # ---------------------------------------------------------------------------
  services.jellyfin = {
    enable = true;
    package = pkgs.jellyfin;

    # The module's own StateDirectory convention: dataDir and cacheDir are the
    # two volumes from incus.nix. Both paths must match the volume `path`
    # fields exactly -- jellyfin will not create them, Incus mounts them.
    dataDir = "/var/lib/jellyfin";
    cacheDir = "/var/cache/jellyfin";

    # There is deliberately NO `address` option here. services.jellyfin has no such
    # option -- the module passes only --datadir/--configdir/--cachedir/--logdir
    # to the binary and Jellyfin binds every interface itself (8096 plain, 8920
    # TLS). An earlier version of this file set address = "0.0.0.0" and the
    # module rejected it by name:
    #
    #   error: The option `services.jellyfin.address' does not exist.
    #
    # Reaching it from Caddy over incusbr0 therefore needs nothing here. What
    # keeps it off the LAN is the absence of any networkForward in ./incus.nix,
    # not a bind address.

    user = "jellyfin";

    # The module's own group. NOT the media group: the library is mounted
    # read-only (measured -- see ../modules/media-instance.nix), so there is no
    # group write to arrange and pinning primary group 972 would be a fiction.
    # Jellyfin's own writes go to its config and cache volumes, which are pool
    # volumes and carry ownership correctly into the container.
    group = "jellyfin";

    # -------------------------------------------------------------------------
    # VAAPI hardware transcoding -- the load-bearing part of this port.
    # -------------------------------------------------------------------------
    #
    # The k3s deployment passed /dev/dri through and reserved
    # `resources.limits."devic.es/dri": "1"`, so transcoding was
    # hardware-accelerated there and must be here too.
    #
    # Two things have to line up, and each is one file:
    #
    #   1. A bare `gpu` device in ./incus.nix. MEASURED: renderD128 arrives
    #      inside the container as 0666 (world read/write), so the jellyfin user
    #      can open it as itself. No uid/gid and no idmap -- Incus 7.0.1's gpu
    #      device has no raw.idmap.* key, and its uid/gid options mean the owner
    #      as seen INSIDE the instance.
    #   2. Here: hardwareAcceleration.type = "vaapi" and device =
    #      /dev/dri/renderD128, which the module writes into Jellyfin's own
    #      <HardwareAccelerationType> and <VaapiDevice> config. This is nixpkgs
    #      doing it properly -- NOT a hand-rolled hardware.opengl stanza.
    #
    # modules/media-idmap.nix's render(303)/video(26) gids are NOT part of this
    # path. They were assumed to be and are not; the 0666 render node is what
    # makes it work. See ./incus.nix for the measurement.
    #
    # hardware.opengl is deliberately NOT set here: Jellyfin needs a VAAPI
    # driver in the container (intel-media-driver / libva), not the desktop GL
    # stack, and enabling hardware.opengl would pull the wrong set and risk
    # masking the VAAPI path. The driver is added below as intel-media-driver.
    hardwareAcceleration = {
      enable = true;
      type = "vaapi";
      # The VAAPI render node the gpu device exposes. This is the standard
      # render node name; verify with `ls /dev/dri/renderD*` inside the
      # instance at apply time.
      device = "/dev/dri/renderD128";
    };
  };

  # ---------------------------------------------------------------------------
  # The VAAPI userspace driver
  # ---------------------------------------------------------------------------
  #
  # The GPU device hands the container /dev/dri (the kernel side). The userspace
  # half -- libva and the Intel driver that talks to it -- has to be present in
  # the Jellyfin container or hardwareAcceleration renders a black frame and
  # Jellyfin falls back to software without saying why. jellyfin-ffmpeg (which
  # services.jellyfin already pulls in) links against these, so they have to be
  # on the library path for the service.
  #
  # intel-media-driver is the Intel driver (Broadwell HD Graphics 5 and up).
  # The host's iGPU generation decides whether this or i965-era intel-media-
  # driver-open is right; both are packaged and either works on most Intel
  # iGPUs -- see NOTES.md, where the verification step is Jellyfin's own
  # playback log reporting the chosen VAAPI driver.
  #
  # libva-utils gives `vainfo`, which is how VAAPI is verified to have actually
  # initialised rather than merely being configured -- see NOTES.md.
  environment.systemPackages = [
    pkgs.curl
    pkgs.intel-media-driver
    pkgs.libva-utils
  ];

  # ---------------------------------------------------------------------------
  # Why there are NO render/video group memberships here
  # ---------------------------------------------------------------------------
  #
  # The first version of this file put the jellyfin user in render and video so
  # it could open /dev/dri/renderD128, and the gpu device carried an idmap to
  # match. Measured on this host with a bare `gpu` device:
  #
  #   crw-rw-rw- 1 root root 226,128 /dev/dri/renderD128
  #
  # renderD128 arrives 0666 -- world read/write -- so ANY user in the container
  # can open it, and no group is required. Incus 7.0.1's gpu device has no
  # raw.idmap.* option at all; its uid/gid keys set the owner as seen INSIDE the
  # instance, which is a different mechanism from the one that was assumed here.
  #
  # So these memberships are omitted deliberately rather than forgotten. If a
  # future iGPU exposes its render node as 0660 (as card0 is), the fix is to add
  # `mode = "0666"` to the gpu device in ./incus.nix -- not to chase gids that
  # the device does not consume.
}