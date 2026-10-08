# NixOS system for the Incus instance "syncthing".
#
# Syncthing as the homelab's replication hub: one always-on node that holds a
# peer's personal files and, later, read-only copies of other instances' data
# volumes. This replaced a k3s HelmRelease (apps/syncthing/, now deleted).
#
# See incus.nix for the Incus half (volumes, the 22000 forward, limits) and
# NOTES.md beside this file for the replication standard other instances
# follow to expose data here.
{ lib, pkgs, ... }:
let
  # The folders this hub originates. A folder here is the server's own; a folder
  # a peer (re)introduces is received, not declared -- see NOTES.md for that
  # rule.
  folderName = "personal";

  # This hub's peers, declared like everything else. A peer's device ID is the
  # only value in this repository that cannot be derived from anything: it is
  # the SHA-256 of that peer's own certificate. Read it from the peer's WebUI
  # (Actions -> Show ID) or `syncthing --device-id` and paste it here; a wrong
  # ID does not error, it just never connects.
  #
  # `folders` is the peer's membership. The `devices` list of every folder below
  # is derived from it, so a new peer is added in exactly one place and the two
  # cannot drift.
  #
  # `addresses` is left unset on every peer: the default is ["dynamic"], which
  # is right for how WE reach them. Peers are behind their own NAT; they dial
  # the host's forwarded 192.168.178.200:22000, not the other way round.
  peers = {
    Dendra = {
      id = "KO655P2-Z2MGQ2G-TVJ7EZD-YHUSBBK-VEPPD7F-55ZYVQR-WYFAIKX-XNENIQQ";
      # An introducer is trusted to introduce other devices and folders to this
      # server, accepted without a manual WebUI accept. That is power, so it
      # belongs to the admin's own device only; a peer gets it by deliberate
      # promotion here, never by default.
      introducer = true;
      folders = [ folderName ];
    };
    Phone = {
      id = "XEHPA3V-IRL2YWY-NWZLQBD-BGQPA6M-6YMLMJ6-TWTLL4S-DQ4SWEH-LOCV2QU";
      folders = [ folderName ];
    };
    Tablet = {
      id = "SNYIG75-W45Q76Z-WG75WFD-CYHWXW4-ZYAHQVX-2XY63I4-BIMXXRX-O2BI3Q4";
      folders = [ folderName ];
    };
  };

  # The name of each peer that is part of `folder`, derived from the table above
  # rather than repeated next to each folder's definition.
  peersOf = folder:
    lib.filter (peer: lib.elem folder peers.${peer}.folders) (lib.attrNames peers);

  # The Syncthing device declarations, derived from the same table so a peer is
  # described in exactly one place.
  deviceSettings = lib.mapAttrs (name: peer: {
    inherit name;
    id = peer.id;
    introducer = peer.introducer or false;
  }) peers;
in
{
  networking.hostName = "syncthing";

  # Same posture as caddy/dns/forgejo: the host and Incus are what gate inbound
  # traffic -- Caddy's VPN gate on the GUI, the 22000 network forward for sync.
  # A second firewall in the guest would only re-filter what the host already
  # let through.
  networking.firewall.enable = false;

  # Address comes from Incus' dnsmasq on incusbr0. Same as caddy/dns: the router,
  # not the host's own .200 (which is the dns instance).
  networking.nameservers = [ "192.168.178.1" ];

  # Not exposed (Incus reaches the instance via exec, and nothing forwards 22).
  services.openssh.enable = false;

  # curl, for reaching the REST API from `incus exec syncthing -- curl ...` when
  # the WebUI is not at hand. The Syncthing binary itself is added by the module.
  environment.systemPackages = [ pkgs.curl ];

  # ---------------------------------------------------------------------
  # Syncthing
  # ---------------------------------------------------------------------
  services.syncthing = {
    enable = true;

    # Run as root, and this is load-bearing rather than convenient. The plan is
    # for this instance to mount other instances' data volumes read-only; those
    # hold files owned by the producer's non-root uids, which map to non-root
    # uids here too. Reading them needs CAP_DAC_OVERRIDE, which only root has.
    #
    # The consequence is the PrivateUsers override at the bottom of this file.
    user = "root";
    group = "root";

    # Config, keys and the index database all live here (configDir defaults to
    # ${dataDir}/.config/syncthing at this stateVersion). This is a volume, and
    # it is the one thing here that snapshots actually protect: the device
    # identity is the certificate in this directory, and losing it changes the
    # server's device ID and breaks every peer.
    dataDir = "/var/lib/syncthing";

    # Caddy dials this over the bridge and sends Host: syncthing.sakul-flee.de.
    # Syncthing rejects a request whose Host header it does not recognise, so the
    # host check is disabled below. No GUI password: the VPN gate in front is the
    # authentication, and this address has no network forward at all -- it is
    # reachable only from inside incusbr0 or through Caddy.
    guiAddress = "0.0.0.0:8384";

    # The declared set IS the truth. `syncthing-init` POSTs these on every boot
    # and DELETEs anything else, so a device or folder added in the WebUI works
    # until the next restart and then vanishes. That is the point: the WebUI is
    # a status view, and adding a peer is a commit. See NOTES.md.
    overrideDevices = true;
    overrideFolders = true;

    settings = {
      gui.insecureSkipHostcheck = true;

      # Derived from `peers` above; adding a peer is one entry in that table.
      devices = deviceSettings;

      folders = {
        # Deliberately a subdirectory of the syncthing-data volume, and not
        # /data itself: Syncthing does not support nesting one shared folder
        # inside another, and the "select independent folders" the plan leaves
        # room for are siblings under /data rather than children of this one.
        ${folderName} = {
          id = folderName;
          label = "Personal";
          path = "/data/${folderName}";
          # sendreceive, not sendonly. The trashcan versioning below only means
          # something on a folder that receives -- a sendonly folder never
          # applies a peer's deletion or replacement, so nothing is ever
          # versioned. If the server is ever meant to be the sole source of this
          # folder instead, this becomes sendonly and the versioning block is
          # dead weight.
          type = "sendreceive";
          devices = peersOf folderName;

          # inotify watching rather than periodic rescans: changes are noticed as
          # they are written. The host's fs.inotify.max_user_watches is raised in
          # hosts/homelab/kernel.nix, because containers share the host kernel and
          # the default per-UID budget is easily exceeded by a large tree -- and
          # the failure is a log line and a silent fallback, not a startup error.
          fsWatcherEnabled = true;

          # Deleted or replaced files are moved into .stversions inside the folder
          # and kept 14 days, which is the recovery window for a mistake that
          # Syncthing propagates before anyone notices.
          versioning = {
            type = "trashcan";
            params.cleanoutDays = "14";
          };
        };
      };
    };
  };

  # The module hardcodes PrivateUsers = true on syncthing.service. That puts the
  # service in its own user namespace where every uid except its own maps to
  # nobody, so root cannot DAC-override into another instance's volume no matter
  # what capabilities it holds. The container is already unprivileged, so
  # removing this keeps root scoped to the container's idmap rather than the
  # host's.
  systemd.services.syncthing.serviceConfig.PrivateUsers = lib.mkForce false;
}
