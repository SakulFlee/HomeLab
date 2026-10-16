# NixOS system for the Incus instance "omniroute".
#
# OmniRoute (diegosouzapw/OmniRoute) -- an all-in-one AI gateway: a unified
# OpenAI-compatible /v1 API in front of many providers, with load balancing,
# failover, credentials management and a dashboard. Packaged from the npm
# release in ./package.nix; this file is everything around it.
#
# Two things about the security posture, both deliberate:
#
#   * REQUIRE_API_KEY=true. The dashboard mints a gateway key and /v1 needs
#     one. The VPN gate in caddy/default.nix is the first layer; this is the
#     second, and it is the one that matters if a VPN device is ever
#     compromised -- an unauthenticated /v1 is an open wallet.
#   * A real guest firewall, unlike every other instance in this repository.
#     Those disable it because the host firewall is the boundary and they
#     listen for nothing. OmniRoute does listen, on a port that spends money,
#     so the port is opened on eth0 only: the host, the other LXCs and
#     Caddy's VPN-gated proxy are on the bridge; the LAN has no route to
#     10.0.0.0/24 at all, and there is no incus network forward. Binding
#     stays 0.0.0.0 inside the app (it is a single-port server behind this
#     filter), and no name is published anywhere but the VPN vhost.
{ config, lib, pkgs, ... }:
let
  # Where incus/apply.sh renders the four secrets. Written by the host into
  # the omniroute-secrets volume -- see incus.nix.
  secretsDir = "/var/lib/incus-secrets";

  omniroute = pkgs.callPackage ./package.nix { };
in
{
  networking.hostName = "omniroute";

  # The exception the file header argues for: default-deny inbound, with
  # 20128/tcp accepted only where it arrives on eth0. Loopback is always
  # allowed by the NixOS firewall module, so the app's own probes keep
  # working. Anything that is not the bridge -- a LAN host that somehow got a
  # route, a future networkForward someone adds by mistake -- is dropped here
  # rather than reaching an API that can spend money.
  networking.firewall = {
    enable = true;
    interfaces.eth0.allowedTCPPorts = [ 20128 ];
  };

  # The router, like every other instance. The gateway dials provider APIs on
  # the internet; this is not optional.
  networking.nameservers = [ "192.168.178.1" ];

  # Nothing here is worth logging into; `incus exec` goes through the API.
  services.openssh.enable = false;

  # No sops, no age, no decryption capability: the four secrets arrive as
  # rendered KEY=value files the host writes in (incus.nix, the
  # caddy/renovate/hermes pattern). A root process in here can read its own
  # gateway credentials and cannot read the restic password, the Forgejo
  # secrets or anything else out of the host's secrets.yaml.

  environment.systemPackages = [
    pkgs.curl
    pkgs.jq
    omniroute
  ];

  # ---------------------------------------------------------------------------
  # The account and its state directory
  # ---------------------------------------------------------------------------
  #
  # A static user, not DynamicUser: DATA_DIR on the omniroute-data volume has
  # to keep its ownership across restarts and across image rebuilds, and a
  # DynamicUser's StateDirectory would live under /var/lib/private and evaporate
  # with the unit. The volume is mounted at /var/lib/omniroute (incus.nix), so
  # this tmpfiles rule is what chowns the mountpoint -- StateDirectory= cannot
  # be used against an Incus-managed mount, same as caddy's tmpfiles rule.
  users.groups.omniroute = { };

  users.users.omniroute = {
    isSystemUser = true;
    group = "omniroute";
    description = "OmniRoute AI gateway";
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/omniroute 0755 omniroute omniroute"
  ];

  # ---------------------------------------------------------------------------
  # The unit
  # ---------------------------------------------------------------------------
  systemd.services.omniroute = {
    description = "OmniRoute AI gateway";

    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # Configuration, not secrets -- everything here is readable by anyone who
    # can reach the instance, and that is the point: only the four values that
    # grant spending power live in the rendered files below.
    #
    #   DATA_DIR             the mounted volume: SQLite DB, encrypted provider
    #                        credentials, content-addressed internal backups.
    #                        Btrfs underneath, which is what upstream's
    #                        migration-safety requirement asks for.
    #   PORT                 the one port: dashboard, API and /v1 together.
    #   REQUIRE_API_KEY      the second gate behind the VPN vhost. See the
    #                        file header.
    #   NODE_ENV             production, per upstream's systemd guidance.
    #   NO_UPDATE_NOTIFIER   their update check is a client-side nicety and
    #                        would only add a network call to every start.
    environment = {
      DATA_DIR = "/var/lib/omniroute";
      PORT = "20128";
      REQUIRE_API_KEY = "true";
      NODE_ENV = "production";
      NO_UPDATE_NOTIFIER = "1";
    };

    serviceConfig = {
      # The four secrets, as four KEY=value files written by apply.sh. Same
      # reasoning as renovate's unit: LoadCredential= is wiped by the LXC
      # image's systemd generator (measured -- see hosts/renovate/default.nix),
      # EnvironmentFile= survives. systemd opens each file as root before
      # dropping to User= below, so 0400 root:root is correct.
      #
      # Not optional, and the first deploy depends on it: a missing
      # EnvironmentFile= source fails the unit outright rather than starting
      # without the variables. apply.sh renders the files and then restarts
      # this unit (unconditionally, after reset-failed) -- see incus.nix.
      EnvironmentFile = [
        "${secretsDir}/omniroute-jwt-secret-env"
        "${secretsDir}/omniroute-api-key-secret-env"
        "${secretsDir}/omniroute-initial-password-env"
        "${secretsDir}/omniroute-storage-encryption-key-env"
      ];

      # `omniroute serve` is upstream's supported headless path: a foreground
      # supervisor over dist/server.js that stays up and supervises. Type=exec
      # rather than notify -- the serve wrapper has optional sd_notify support,
      # and a unit that hangs until timeout because a notification never
      # arrives is a worse failure than one that reports started at execve.
      ExecStart = "${omniroute}/bin/omniroute serve";
      User = "omniroute";
      Group = "omniroute";

      # A crash net, not a feature: the supervisor only exits if something is
      # genuinely broken, and a gateway that stopped silently is the worst
      # outcome. 30s rather than the default 100ms so a bad provider config
      # does not become a start loop.
      Restart = "always";
      RestartSec = 30;

      # Modest hardening. Not sealed shut: the app writes DATA_DIR (on the
      # volume, so ProtectSystem=full -- /usr, /boot, /etc read-only -- leaves
      # it writable) and dials out to providers. PrivateTmp and friends cost
      # nothing here.
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "full";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      LockPersonality = true;
      RestrictRealtime = true;
      SystemCallArchitectures = "native";
    };
  };
}
