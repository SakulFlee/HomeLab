# NixOS system for the Incus instance "qui".
#
# QUI (the qBittorrent WebUI) from the nixpkgs services.qui module.
#
# QUI authenticates qBittorrent users with a session secret, and the module
# requires it as a FILE (secretFile), refusing an inline value because the
# rendered config lands in the world-readable nix store. So the secret is
# generated once onto the /config volume by a oneshot and read from there --
# the same shape paperless uses for its secret key on its data volume, and for
# the same reason.
#
# The secret is generated, not imported, because this is a clean instance (no
# k3s data import) and a session secret is instance-local. QUI's own session
# cookies are invalidated by a rotate, which is the correct behaviour for a
# fresh deployment.
{ config, lib, pkgs, ... }:
let
  # Where the module expects the session-secret file, on the qui-config volume
  # from ./incus.nix (mounted at /config).
  secretFile = "/config/session-secret";
in
{
  imports = [ ../../modules/media-instance.nix ];

  networking.hostName = "qui";

  environment.systemPackages = [ pkgs.curl ];

  # The three library shares QUI reads, plus qBittorrent which it mounts at its
  # own path (see ./incus.nix). All four are read-only from QUI's perspective
  # except that it hardlinks/downloads out of qBittorrent -- but QUI never
  # writes the library, so the /mnt/nas ones are ro.
  mediaInstance.mountedShares = [
    "Movies"
    "Shows"
    "NSFW"
  ];

  # ---------------------------------------------------------------------------
  # The session secret, provisioned once onto the config volume
  # ---------------------------------------------------------------------------
  #
  # 64 hex chars (openssl rand -hex 32), matching the module's own guidance.
  # umask 0377 and mode 0600 so the only reader is the qui user. Generated only
  # if absent, so a recreate keeps existing sessions valid.
  #
  # Runs before qui.service because the module's unit does
  # `LoadCredential=sessionSecret:${cfg.secretFile}`, and systemd FAILS the unit
  # if a LoadCredential source is missing -- so this must be an ordering
  # dependency, not just a multi-user.target neighbour.
  systemd.services.qui-session-secret = {
    description = "Provision the QUI session secret on the config volume";
    wantedBy = [ "multi-user.target" ];
    before = [ "qui.service" ];
    after = [ "local-fs.target" ];
    path = [ pkgs.coreutils pkgs.openssl ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      umask 0377
      if [ ! -s "${secretFile}" ]; then
        openssl rand -hex 32 > "${secretFile}"
      fi
      # root:root, 0600. NOT qui:qui -- this file is the LoadCredential SOURCE,
      # read by systemd as root before the service starts, and systemd then
      # delivers it into $CREDENTIALS_DIRECTORY for the service. The service
      # never reads this path directly. An earlier version chowned it to
      # qui:qui, which is both unnecessary (the service never opens this file)
      # and insufficient (the credential copy the service actually reads was
      # still unreadable, for the PrivateUsers reason documented below).
      chown root:root "${secretFile}"
      chmod 0600 "${secretFile}"
    '';
  };

  # The module hardcodes PrivateUsers = true alongside its LoadCredential, and
  # the two are mutually incompatible here:
  #
  #   qui: {"level":"fatal","error":"open
  #   /run/credentials/qui.service/sessionSecret: permission denied",
  #   "message":"Could not read QUI__SESSION_SECRET_FILE"}
  #
  # PrivateUsers puts the service in a user namespace where only uid 0 maps
  # normally, so the credential systemd delivers -- owned by the real `qui` uid
  # -- is unreadable inside it. The service cannot start at all.
  #
  # PrivateUsers is turned off for this one instance. It is a real reduction in
  # hardening, and it is the lesser evil compared to the alternative (a service
  # that cannot read the secret it requires and never starts). The other
  # protections the module applies are left in place and still meaningful:
  # CapabilityBoundingSet="", NoNewPrivileges, ProtectSystem=full (which is what
  # lets qui hardlink torrent files), ProtectProc, RestrictNamespaces,
  # MemoryDenyWriteExecute, SystemCallArchitectures=native and the systemd
  # syscall filter.
  #
  # An alternative that keeps PrivateUsers would be to stop using
  # LoadCredential and put the secret somewhere root-only that the service
  # reads directly -- but the module's unit reads $CREDENTIALS_DIRECTORY, so
  # that means replacing the unit's ExecStart, which is a larger change than
  # relaxing one hardening flag. Revisit if the namespace hardening is wanted
  # back.
  systemd.services.qui = {
    # mkForce, not a bare value: the module sets PrivateUsers = true at the same
    # priority, so a plain `PrivateUsers = false` conflicts rather than
    # overrides.
    serviceConfig.PrivateUsers = lib.mkForce false;
  };

  # ---------------------------------------------------------------------------
  # QUI
  # ---------------------------------------------------------------------------
  services.qui = {
    enable = true;
    package = pkgs.qui;

    user = "qui";
    group = "media";

    # The generated session secret, read by the unit via LoadCredential.
    secretFile = secretFile;

    settings = {
      # Caddy dials in over incusbr0, so bind all interfaces. The module's
      # default is 127.0.0.1, which would NOT be reachable from Caddy -- stated
      # explicitly so it does not silently regress to loopback-only.
      host = "0.0.0.0";

      # 7476 is the port the k3s deployment exposed and the port the Caddy
      # vhost will target.
      port = 7476;

      logLevel = "INFO";
    };

    # The module hardens the unit with ProtectSystem="full" specifically so qui
    # can hardlink torrent files (its own comment says so). That is what makes
    # the qBittorrent download share usable for hardlinking. The library shares
    # are read-only at the device level regardless.
  };
}