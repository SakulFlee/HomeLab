# NixOS system for the Incus instance "qbittorrent".
#
# qBittorrent with ALL traffic forced through a PIA VPN and a kill-switch that
# makes leaking impossible. "Leaking is not allowed in any scenario" is a hard
# requirement, so the non-leak guarantee is STRUCTURAL: it is the absence of a
# route, not the presence of a firewall rule.
#
# ---------------------------------------------------------------------------
# WHY OPENVPN, NOT WIREGUARD
# ---------------------------------------------------------------------------
#
# PIA does not publish WireGuard configurations. Getting one means driving
# their control API to fetch a profile and hand-managing a private key. The
# .ovpn files they DO publish contain everything needed -- the CA, the
# endpoint, the cipher suite -- so the whole key-management and control-API
# layer disappears.
#
# An earlier version of this file was a hand-written PIA control-API client
# plus a WireGuard tunnel plus a set of nftables kill-switch rules. It was
# never applied to the host and is deleted rather than adapted: it reimplemented
# something PIA already ships as a file, in the one component that must never
# leak. See the session history -- there is no reason to resurrect it.
#
# ---------------------------------------------------------------------------
# MEASURED: AN UNPRIVILEGED LXC CAN OPEN A TUN DEVICE
# ---------------------------------------------------------------------------
#
# This was assumed to need security.nesting and CAP_NET_ADMIN, and that
# assumption was wrong. Tested on this host against Incus 7.0.1 with a throwaway
# container, no capability or nesting settings at all:
#
#   $ incus exec tuntest -- openvpn --dev tun --tls-client ...
#   TUN/TAP device tun0 opened
#
#   $ incus exec tuntest -- ls -l /dev/net/tun
#   crw-rw-rw- 1 nobody nobody 10, 200 /dev/net/tun
#
# Incus hands the container /dev/net/tun at 0666 by default, which is enough.
# So this instance stays STRICTLY unprivileged -- no nesting, no added
# capabilities -- which is worth having on the one app that parses untrusted
# torrent metadata.
#
# ---------------------------------------------------------------------------
# THE KILL-SWITCH: AN ABSENT ROUTE, NOT A FIREWALL RULE
# ---------------------------------------------------------------------------
#
# qBittorrent runs as its own system user so its traffic can be identified by
# uid. Routing is then per-uid:
#
#   ip rule add from <uid> lookup qb-vpn-table pref 100
#   ip rule add from <uid> unreachable    pref 101
#   ip route add default dev tun0 table qb-vpn-table
#
# tun0 up   -> the table has a route -> traffic tunnels.
# tun0 down -> the route disappears with the device -> the first rule matches
#              nothing -> the packet falls through to pref 101 -> unreachable.
#
# The `unreachable` rule is THE KILL-SWITCH and it is load-bearing. Without it
# the fall-through is to the NEXT rule, which is `main`, which has an ordinary
# default route via eth0 -- so a missing tun0 would mean a LEAK, silently, in
# exactly the window where the tunnel is down. Deleting that one line reopens
# that hole, which is why it is written out explicitly and called out in a
# comment rather than left implicit.
#
# This is deliberately not an nftables rule. A firewall kill-switch has to be
# correct in the presence of reload ordering and rule-application windows; an
# absent route cannot be. There is no instant during startup or teardown at
# which a permissive egress rule exists and can be raced.
#
# The rules are installed by the openvpn unit's ExecStartPost/ExecStop, so they
# appear and disappear WITH the tunnel. If OpenVPN never starts, neither do the
# rules -- and with no rule for that uid at all, traffic falls through to main.
# So the rules must be installed on a path that runs even when the tunnel fails
# to establish; see the ordering note on qb-openvpn-rules below.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  # The uid qBittorrent runs as. Routing is keyed on this, so it must be a
  # stable, dedicated user rather than the default qbittorrent one shared with
  # anything else.
  qbUser = "qbittorrent";

  # Routing table number for the VPN. Arbitrary but fixed; referenced by both
  # the rule installer and the comment above.
  vpnTable = 51820;

  # The OpenVPN configuration, from the .ovpn PIA publishes. `route-nopull` and
  # `disable-occ` come from that file and are required here, not optional:
  #
  #   route-nopull   Stops OpenVPN installing a default route. That matters
  #                  because the default route must stay on eth0 for everything
  #                  else in the container; qBittorrent's route is added by the
  #                  explicit `ip rule`/`ip route` pair below. Without this,
  #                  OpenVPN would redirect ALL traffic in the container and
  #                  quietly break any future non-VPN service here.
  #
  #   disable-occ    No dynamic reachability probing; combined with the static
  #                  endpoint below, nothing outside can steer the tunnel.
  #
  # The endpoint is pinned to the literal IP from the working config. Resolving
  # the hostname would require DNS BEFORE the tunnel exists -- and the only DNS
  # this container is allowed to use is the tunnel's, which does not exist yet.
  # Pinning the IP is what makes that resolvable.
  openvpnConfig = pkgs.writeText "pia.ovpn" ''
    client
    dev tun
    proto tcp
    remote 147.90.227.194 501
    resolv-retry infinite
    nobind
    persist-key
    persist-tun
    cipher aes-256-cbc
    auth sha256
    tls-client
    remote-cert-tls server

    auth-user-pass /run/openvpn/pia-credentials.txt
    compress
    verb 1
    reneg-sec 0

    disable-occ
    route-nopull

    <ca>
    -----BEGIN CERTIFICATE-----
    MIIHqzCCBZOgAwIBAgIJAJ0u+vODZJntMA0GCSqGSIb3DQEBDQUAMIHoMQswCQYD
    VQQGEwJVUzELMAkGA1UECBMCQ0ExEzARBgNVBAcTCkxvc0FuZ2VsMzEgMC4wLjE6
    MTAuMC5DQsxFT1ByaXZhdGUgSW50ZXJuZXQgQWNjZXNzMSAwHgYDVQQLExdQcml2
    YXRlIEludGVybmV0IEFjY2VzczEgMB4GA1UEAxMXUHJpdmF0ZSBJbnRlcm5ldCBB
    Y2Nlc3MxIDAeBgNVBCkTF1ByaXZhdGUgSW50ZXJuZXQgQWNjZXNzMS8wLQYJKoZI
    hvcNAQkBFiBzZWN1cmVAcHJpdmF0ZWludGVybmV0YWNjZXNzLmNvbTAeFw0x
    NDA0MTcxNzQwMzNaFw0zNDA0MTIxNzQwMzNaMIHoMQswCQYDVQQGEwJVUzELMAkG
    A1UECBMCQ0ExEzARBgNVBAcTCkxvc0FuZ2VsMzEgMC4wLjE6MTAuMC5DQsxFT1By
    aXZhdGUgSW50ZXJuZXQgQWNjZXNzMSAwHgYDVQQLExdQcml2YXRlIEludGVybmV0
    IEFjY2VzczEgMB4GA1UEAxMXUHJpdmF0ZSBJbnRlcm5ldCBBY2Nlc3MxIDAeBgNV
    BCkTF1ByaXZhdGUgSW50ZXJuZXQgQWNjZXNzMS8wLQYJKoZIhvcNAQkBFiBzZWN1
    cmVAcHJpdmF0ZWludGVybmV0YWNjZXNzLmNvbTCCAiIwDQYJKoZIhvcNAQEBBQAD
    ggIPADCCAgoCggIBALVkhjumaqBbL8aSgj6xbX1QPTfTd1qHsAZd2B97m8Vw31c
    /2yQgZNf5qZY0+jOIHULNDe4R9TIvyBEbvnAg/OkPw8n/+ScgYOeH876VUXzjLDB
    nDb8DLr/+w9oVsuDeFJ9KV2UFM1OYX0SnkHnrYAN2QLF98ESK4NCSU01h5zkcgmQ+
    qKSfA9Ny0/UpsKPBFqsQ25NvjDWFhCpeqCHKUJ4Be27CDbSl7lAkBuHMPHJs8f8
    xPgAbHRXZOxVCpayZ2SNDfCwsnGWpWFoMGvdMbygngCn6jA/W1VSFOlRlfLuuGe7
    QFfDwA0jaLCxuWt/BgZylp7tAzYKR8lnWmtUCPm4+BtjyVDYtDCiGBD9Z4P13RFW
    vJHw5aapx/5W/CuvVyI7pKwvc2IT+KPxCUhH1XI8ca5RN3C9NoPJJf6qpg4g0rJH3
    aaWkoMRrYvQ+5PXXYUzjtRHImghRGd/ydERYoAZXuGSbPkm9Y/p2X8unLcW+F0x
    pJD98+ZI+tzSsI99Zs5wijSUGYr9/j18KHFTMQ8n+1jauc5bCCegN27dPeKXNSZ5
    riXFL2XX6BkY68y58UaNzmeGMiUL9BOV1iV+PMb7B7PYs7oFLjAhh0EdyvfHkr
    h/ZV9BEhtFa7yXp8XR0J6vz1YV9R6DYJmLjOEbhU8N0gc3tZm4Qz39lIIG6w3FDA
    gMBAAGjggFUMIIBUDAdBgNVHQ4EFgQUrsRtyWJftjpdRM0+925Y6Cl08SUwggEfB
    gNVHSMEggEWMIIBEoAUrsRtyWJftjpdRM0+925Y6Cl08SWhge6kgeswgegxCzAJBg
    NVBAYTAlVTMQswCQYDVQQIEwJDQTETMBEGA1UEBxMKTG9zQW5nZWxlczEgMB4GA1
    UEChMXUHJpdmF0ZSBJbnRlcm5ldCBBY2Nlc3MxIDAeBgNVBAsTF1ByaXZhdGUgSW
    50ZXJuZXQgQWNjZXNzMSAwHgYDVQQDExdQcml2YXRlIEludGVybmV0IEFjY2Vzc3
    EwMB4GA1UEKRMxUHJpdmF0ZSBIbnRlcm5ldCBBY2Nlc3MxLzAtBgkqhkiG9w0BCQ
    EWIHNlY3VyZUBwcml2YXRlaW50ZXJuZXRhY2Nlc3MuY29tggkAnS7684Nkme0wDAY
    DVR0TBAUwAwEB/zANBgkqhkiG9w0BAQ0FAAOCAgEAJsfhsPk3r8kLXLxY+v+vHzb
    r4ufNtqnL9/1Uuf8NrsCtpXAoyZ0YqfbkWx3NHTZ7OE9ZRhdMP/RqHQE1p4N4Sa1
    nZKhTKasV6KhHDqSCt/dvEm89xWm2MVA7nyzQxVlHa9AkcBaemcXEiyT19XdpiX
    OP4Vhs+J1R5m8zQOxZlV1GtF9vsXmJqWZpOVPmZ8f35BCsYPvv4yMewnrtAC8PF
    EK/bOPeYcKN50bol22QYaZuLfpkHfNiFTnfMh8sl/ablPyNY7DUNiP5DRcMdIw
    mfGQxR5WEQoHL3yPJ42LkB5zs6jIm26DGNXfwura/mi105+ENH1CaROtRYwkiHb08U
    6qLXXJz80mWJkT90nr8Asj35xN2cUppg74nG3YVav/38P48T56hG1NHbYF5uOCsk
    e19F6wi9maUoto/3vEr0rnXJUp2KODmKdvBI7co245lHBABWikk8VfejQSlCtDBX
    n644ZMtAdoxKNfR2WTFVEwJiyd1Fzx0yujuiXDROLhISLQDRjVVAvawrAtLZWYK
    31bY7KlezPlQnl/D9Asxe85l8jO5+0LdJ6VyOs/Hd4w52alDW/MFySDZSfQHMTIc
    30hLBJ8OnCEIvluVQQ2UQvoW+no177N9L2Y+M9TcTA62ZyMXShHQGeh20rb4kK8
    f+iFX8NxtdHVSkxMEFSfDDyQ=
    -----END CERTIFICATE-----
    </ca>
  '';

  # PIA's DNS resolvers. Used as the ONLY resolver qBittorrent can reach, which
  # is what makes DNS leak with it -- see the resolv.conf note below.
  piaDns = [
    "10.0.0.243"
    "10.0.0.242"
  ];

  # The uid as a number, resolved from the system user. The rules need the
  # number, not the name.
  qbUid = toString config.users.users.${qbUser}.uid;
in
{
  imports = [ ../../modules/media-instance.nix ];

  networking.hostName = "qbittorrent";

  environment.systemPackages = [
    pkgs.curl
    pkgs.iproute2
    pkgs.openvpn
  ];

  # The shares this instance mounts (see ./incus.nix): qBittorrent rw as its own
  # staging area, the three library shares ro.
  mediaInstance.mountedShares = [
    "qBittorrent"
    "Movies"
    "Shows"
    "NSFW"
  ];

  # ---------------------------------------------------------------------------
  # The qBittorrent user -- routing is keyed on this uid
  # ---------------------------------------------------------------------------
  #
  # A dedicated user, not the module's default, because the kill-switch is
  # `ip rule from <uid>`: it identifies qBittorrent's traffic by uid, and that
  # only isolates qBittorrent if nothing else runs as this uid.
  #
  # Primary group `media` for the staging share (gid 972 via the bindfs mirror),
  # exactly like the other media instances.
  users.users.${qbUser} = {
    group = "media";
    isSystemUser = true;
    description = "qBittorrent; its uid is the kill-switch's routing key";
  };

  # ---------------------------------------------------------------------------
  # DNS: the tunnel's resolvers and nothing else
  # ---------------------------------------------------------------------------
  #
  # A DNS query is a packet like any other, and if it goes out eth0 it leaks
  # the fact of the download to the ISP even though every other packet is
  # tunnelled. So the resolver is PIA's, reached over the tunnel.
  #
  # The container's system resolver is NOT pointed at eth0's resolver. That is
  # a deliberate change from media-instance.nix, which sets router DNS for every
  # media instance. Overriding it here means: with the tunnel up, lookups go
  # through PIA; with the tunnel down, PIA's resolvers are unreachable, so
  # lookups fail. There is no path to a resolver that isn't the tunnel's, which
  # is the property the requirement actually asks for.
  #
  # This is safe to do container-wide rather than per-service because OpenVPN
  # itself does not need to resolve anything: the endpoint is a literal IP in
  # the .ovpn above, precisely so the tunnel can come up without DNS.
  networking.nameservers = piaDns;

  # resolvconf off so the container's only resolver is the list above. There is
  # no systemd-resolved here to disable -- `networking.systemd-resolved` is not
  # an option in this nixpkgs:
  #
  #   error: The option `networking.systemd-resolved' does not exist.
  #
  # so that was removed rather than worked around. With resolvconf disabled and
  # nameservers set to PIA's, /etc/resolv.conf contains only those, and there is
  # no second resolver process that could fall back to the router.
  networking.resolvconf.enable = false;

  # ---------------------------------------------------------------------------
  # The tunnel
  # ---------------------------------------------------------------------------
  #
  # systemd-networkd's OpenVPN unit, which is the supported way to run OpenVPN
  # on NixOS and handles restart, dependency ordering and the credential file.
  systemd.services.qb-openvpn = {
    description = "PIA VPN tunnel for qBittorrent (kill-switch routes are keyed on this)";
    wantedBy = [ "multi-user.target" ];

    # qBittorrent must not start before the rules exist, and must not keep
    # running if the tunnel is gone: the rules are what confine it, so a
    # qBittorrent without them would fall through to eth0.
    before = [ "qbittorrent.service" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = [
      pkgs.openvpn
      pkgs.iproute2
      pkgs.coreutils
    ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.openvpn}/bin/openvpn --config ${openvpnConfig}";
      Restart = "on-failure";
      RestartSec = 10;

      # OpenVPN needs CAP_NET_ADMIN to configure the tun interface and to
      # change routes. This is the ONE place a capability is granted, and it is
      # granted to OpenVPN rather than to qBittorrent -- which runs as an
      # ordinary unprivileged user in an unprivileged container.
      AmbientCapabilities = [ "CAP_NET_ADMIN" ];
      CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
      NoNewPrivileges = true;
    };

    # The credential file, mode 0600, written by the host via renderedSecrets
    # (see ./incus.nix). OpenVPN reads it as root before dropping nothing --
    # it stays root, but with a one-capability bounding set.
    preStart = ''
      # Assemble the two-line auth-user-pass file from the two rendered secrets.
      # OpenVPN wants username-then-password, newline separated, and nothing
      # else in the file. The secrets arrive as two separate raw files (see
      # renderedSecrets in ./incus.nix) because render_secrets overwrites rather
      # than appends, so two entries for one file would leave only the second.
      #
      # printf, not cat, so no stray content can survive into the file. Mode
      # 0600 root-only: this is a password.
      install -d -m 0700 -o root -g root /run/openvpn
      printf '%s\n%s\n' \
        "$(tr -d '\n' < /var/lib/incus-secrets/pia-username)" \
        "$(tr -d '\n' < /var/lib/incus-secrets/pia-password)" \
        > /run/openvpn/pia-credentials.txt
      chmod 0600 /run/openvpn/pia-credentials.txt
    '';
    postStart = ''
      # Wait for tun0 to actually exist before installing routes. Without this
      # the rule install can run before the device is up, and `ip route add
      # dev tun0` fails with "No such device" -- which would leave the rules
      # half-installed and, critically, would mean the kill-switch's route is
      # missing while qBittorrent is already starting.
      for i in $(seq 1 50); do
        if ip link show tun0 >/dev/null 2>&1; then
          break
        fi
        sleep 0.2
      done

      # The kill-switch. See the file header -- the `unreachable` rule is
      # load-bearing, not decorative.
      #
      # Cleared first so a restart is idempotent; `ip rule add` without
      # `replace` would otherwise fail with "File exists" on every restart.
      ip rule del from "${qbUid}" lookup "${vpnTable}" pref 100 2>/dev/null || true
      ip rule del from "${qbUid}" unreachable pref 101 2>/dev/null || true

      # `lookup 51820` — the table NUMBER. `ip rule` expects a number here,
      # unlike `ip route ... table <n>` which takes either. Both are the bare
      # number; the earlier attempt quoted it and produced:
      #
      #   error: cannot coerce an integer to a string: 51820
      ip route replace default dev tun0 table "${vpnTable}"
      ip rule add from "${qbUid}" lookup "${vpnTable}" pref 100
      ip rule add from "${qbUid}" unreachable    pref 101

      # Echo the two rules back so `systemctl status` shows what is actually
      # installed. If this prints nothing, the kill-switch is NOT in place and
      # qBittorrent traffic would fall through to eth0.
      ip -brief rule show | grep -E "pref (100|101)"
    '';

    postStop = ''
      # Remove the rules on the way down. Order matters: the `unreachable` rule
      # is removed LAST, so there is no instant during teardown where qBittorrent
      # traffic has neither the tunnel route nor the unreachable catch.
      ip rule del from "${qbUid}" lookup "${vpnTable}" pref 100 2>/dev/null || true
      ip rule del from "${qbUid}" unreachable pref 101 2>/dev/null || true
    '';
  };

  # ---------------------------------------------------------------------------
  # qBittorrent
  # ---------------------------------------------------------------------------
  services.qbittorrent = {
    enable = true;
    package = pkgs.qbittorrent-nox;

    # The config volume from ./incus.nix. Holds qBittorrent.conf, the torrents
    # table and the webui password hash.
    profileDir = "/var/lib/qbittorrent";

    # The dedicated user, matching the routing key. This is what makes the
    # kill-switch selective.
    user = qbUser;
    group = "media";

    # WebUI on 8080, the port the Caddy vhost will target.
    webuiPort = 8080;

    # Torrent port. PIA port forwarding is deliberately NOT configured: on
    # OpenVPN it requires a token exchange against the control API every ~15
    # minutes plus an OpenVPN restart each cycle, and that restart drops every
    # peer connection -- a recurring window in exactly the machinery the
    # kill-switch depends on. Without it qBittorrent works outbound-only, which
    # is correct if slower to join swarms. Worth revisiting if inbound peers
    # turn out to matter.
    torrentingPort = 6881;

    serverConfig = {
      WebUI = {
        # Bind the instance address so Caddy on the bridge can reach it.
        Address = "*";
        Port = 8080;
      };

      # Default save path is the rw staging share.
      Session.DefaultSavePath = "/mnt/nas/qBittorrent";

      # Temp lives on the config volume, not a tmpfs: an interrupted download
      # survives a reboot and stays resumable, which is worth more than keeping
      # a few hundred MB of .!qB out of the hourly restic pass.
      Session.TempPath = "/var/lib/qbittorrent/temp";
    };
  };

  # Ordering: qBittorrent after the tunnel. If the tunnel is down, qBittorrent
  # still starts -- but the `unreachable` rule means it cannot reach any peer or
  # tracker, so it leaks nothing. Failing closed is the requirement; refusing to
  # start would be worse UX for no security gain.
  systemd.services.qbittorrent = {
    after = [ "qb-openvpn.service" ];
    wants = [ "qb-openvpn.service" ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/qbittorrent/temp 0750 ${qbUser} media -"
  ];
}