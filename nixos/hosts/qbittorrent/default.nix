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
#   ip rule add pref 100 uidrange <uid>-<uid> lookup qb-vpn-table
#   ip rule add pref 101 uidrange <uid>-<uid> unreachable
#   ip route add default dev tun0 table qb-vpn-table
#
# The selector is `uidrange`, not `from`: `ip rule`'s `from` takes an address or
# prefix and rejects a bare uid outright. See the postStart comment for what that
# cost before it was found.
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
# The rules are owned by their own unit, qb-killswitch, which is wanted at boot
# and runs whether or not OpenVPN succeeds. They deliberately OUTLIVE the tunnel.
#
# An earlier version installed them from the openvpn unit's start and removed
# them on its stop, so the kill-switch appeared and disappeared WITH the thing
# it was protecting. That is backwards: the rules matter most exactly when the
# tunnel is down. Measured on this host with the tunnel stopped under that
# arrangement:
#
#   qb-openvpn: inactive, tun0: gone, rules: []
#   uid 996 egress: 217.224.110.155    <- the home ISP, in the clear
#
# A kill-switch that disarms itself when the tunnel drops is worse than none,
# because it looks armed right up until you test it.
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

  # PINNED, not auto-allocated, because this number is the kill-switch.
  #
  # users.users.<name>.uid defaults to null ("allocate the next free one"), and
  # `toString null` is "", so an auto-allocated uid would silently produce
  #     ip rule add pref 100 uidrange "-" lookup 51820
  # which fails, leaving NO rule at all -- and no rule means traffic falls
  # through to main, i.e. straight out eth0. A kill-switch that silently fails
  # to install is worse than none, because it looks installed.
  #
  # 996 is unused by the other media instances, which sit at 274, 275, 997 and
  # 998. Verified against the running instances before choosing it.
  qbUidNumber = 996;

  # Routing table number for the VPN. Arbitrary but fixed.
  #
  # A STRING, not an integer, and that is not cosmetic. Nix treats a bare
  # /dev/null inside an indented string as a PATH literal, and when a path is
  # present the whole string is coerced with coerceToString -- which cannot
  # coerce an integer. An integer here fails at build time with:
  #
  #   error: cannot coerce an integer to a string: 51820
  #
  # reported at the `lookup` interpolation, several lines away from the cause.
  vpnTable = "51820";

  # The Incus bridge subnet (incusbr0). Traffic to here must NOT be forced into
  # the VPN, or Caddy cannot reach the WebUI on 10.0.0.112:8080 -- see the
  # kill-switch bypass rule below.
  #
  # A literal rather than a shared option because instance addresses are literals
  # too (see ./incus.nix); there is no subnet option in media-instance.nix to
  # read. If the bridge is renumbered, this is the line to change.
  lanSubnet = "10.0.0.0/24";

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
    VQQGEwJVUzELMAkGA1UECBMCQ0ExEzARBgNVBAcTCkxvc0FuZ2VsZXMxIDAeBgNV
    BAoTF1ByaXZhdGUgSW50ZXJuZXQgQWNjZXNzMSAwHgYDVQQLExdQcml2YXRlIElu
    dGVybmV0IEFjY2VzczEgMB4GA1UEAxMXUHJpdmF0ZSBJbnRlcm5ldCBBY2Nlc3Mx
    IDAeBgNVBCkTF1ByaXZhdGUgSW50ZXJuZXQgQWNjZXNzMS8wLQYJKoZIhvcNAQkB
    FiBzZWN1cmVAcHJpdmF0ZWludGVybmV0YWNjZXNzLmNvbTAeFw0xNDA0MTcxNzQw
    MzNaFw0zNDA0MTIxNzQwMzNaMIHoMQswCQYDVQQGEwJVUzELMAkGA1UECBMCQ0Ex
    EzARBgNVBAcTCkxvc0FuZ2VsZXMxIDAeBgNVBAoTF1ByaXZhdGUgSW50ZXJuZXQg
    QWNjZXNzMSAwHgYDVQQLExdQcml2YXRlIEludGVybmV0IEFjY2VzczEgMB4GA1UE
    AxMXUHJpdmF0ZSBJbnRlcm5ldCBBY2Nlc3MxIDAeBgNVBCkTF1ByaXZhdGUgSW50
    ZXJuZXQgQWNjZXNzMS8wLQYJKoZIhvcNAQkBFiBzZWN1cmVAcHJpdmF0ZWludGVy
    bmV0YWNjZXNzLmNvbTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALVk
    hjumaqBbL8aSgj6xbX1QPTfTd1qHsAZd2B97m8Vw31c/2yQgZNf5qZY0+jOIHULN
    De4R9TIvyBEbvnAg/OkPw8n/+ScgYOeH876VUXzjLDBnDb8DLr/+w9oVsuDeFJ9K
    V2UFM1OYX0SnkHnrYAN2QLF98ESK4NCSU01h5zkcgmQ+qKSfA9Ny0/UpsKPBFqsQ
    25NvjDWFhCpeqCHKUJ4Be27CDbSl7lAkBuHMPHJs8f8xPgAbHRXZOxVCpayZ2SND
    fCwsnGWpWFoMGvdMbygngCn6jA/W1VSFOlRlfLuuGe7QFfDwA0jaLCxuWt/BgZyl
    p7tAzYKR8lnWmtUCPm4+BtjyVDYtDCiGBD9Z4P13RFWvJHw5aapx/5W/CuvVyI7p
    Kwvc2IT+KPxCUhH1XI8ca5RN3C9NoPJJf6qpg4g0rJH3aaWkoMRrYvQ+5PXXYUzj
    tRHImghRGd/ydERYoAZXuGSbPkm9Y/p2X8unLcW+F0xpJD98+ZI+tzSsI99Zs5wi
    jSUGYr9/j18KHFTMQ8n+1jauc5bCCegN27dPeKXNSZ5riXFL2XX6BkY68y58UaNz
    meGMiUL9BOV1iV+PMb7B7PYs7oFLjAhh0EdyvfHkrh/ZV9BEhtFa7yXp8XR0J6vz
    1YV9R6DYJmLjOEbhU8N0gc3tZm4Qz39lIIG6w3FDAgMBAAGjggFUMIIBUDAdBgNV
    HQ4EFgQUrsRtyWJftjpdRM0+925Y6Cl08SUwggEfBgNVHSMEggEWMIIBEoAUrsRt
    yWJftjpdRM0+925Y6Cl08SWhge6kgeswgegxCzAJBgNVBAYTAlVTMQswCQYDVQQI
    EwJDQTETMBEGA1UEBxMKTG9zQW5nZWxlczEgMB4GA1UEChMXUHJpdmF0ZSBJbnRl
    cm5ldCBBY2Nlc3MxIDAeBgNVBAsTF1ByaXZhdGUgSW50ZXJuZXQgQWNjZXNzMSAw
    HgYDVQQDExdQcml2YXRlIEludGVybmV0IEFjY2VzczEgMB4GA1UEKRMXUHJpdmF0
    ZSBJbnRlcm5ldCBBY2Nlc3MxLzAtBgkqhkiG9w0BCQEWIHNlY3VyZUBwcml2YXRl
    aW50ZXJuZXRhY2Nlc3MuY29tggkAnS7684Nkme0wDAYDVR0TBAUwAwEB/zANBgkq
    hkiG9w0BAQ0FAAOCAgEAJsfhsPk3r8kLXLxY+v+vHzbr4ufNtqnL9/1Uuf8NrsCt
    pXAoyZ0YqfbkWx3NHTZ7OE9ZRhdMP/RqHQE1p4N4Sa1nZKhTKasV6KhHDqSCt/dv
    Em89xWm2MVA7nyzQxVlHa9AkcBaemcXEiyT19XdpiXOP4Vhs+J1R5m8zQOxZlV1G
    tF9vsXmJqWZpOVPmZ8f35BCsYPvv4yMewnrtAC8PFEK/bOPeYcKN50bol22QYaZu
    LfpkHfNiFTnfMh8sl/ablPyNY7DUNiP5DRcMdIwmfGQxR5WEQoHL3yPJ42LkB5zs
    6jIm26DGNXfwura/mi105+ENH1CaROtRYwkiHb08U6qLXXJz80mWJkT90nr8Asj3
    5xN2cUppg74nG3YVav/38P48T56hG1NHbYF5uOCske19F6wi9maUoto/3vEr0rnX
    JUp2KODmKdvBI7co245lHBABWikk8VfejQSlCtDBXn644ZMtAdoxKNfR2WTFVEwJ
    iyd1Fzx0yujuiXDROLhISLQDRjVVAvawrAtLZWYK31bY7KlezPlQnl/D9Asxe85l
    8jO5+0LdJ6VyOs/Hd4w52alDW/MFySDZSfQHMTIc30hLBJ8OnCEIvluVQQ2UQvoW
    +no177N9L2Y+M9TcTA62ZyMXShHQGeh20rb4kK8f+iFX8NxtdHVSkxMEFSfDDyQ=
    -----END CERTIFICATE-----
    </ca>
  '';

  # PIA's DNS resolvers. Used as the ONLY resolver qBittorrent can reach, which
  # is what makes DNS leak with it -- see the resolv.conf note below.
  piaDns = [
    "10.0.0.243"
    "10.0.0.242"
  ];

  # The uid as a string for the ip rule lines. Reads the PINNED value from the
  # user declaration below rather than auto-allocating -- see qbUidNumber for
  # why that distinction is the whole point of this file.
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

    # PINNED. See qbUidNumber: the routing rules key on this exact number, so
    # auto-allocation would produce `ip rule from "" ...` and no kill-switch.
    uid = qbUidNumber;
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

  # resolvconf off, and /etc/resolv.conf written directly.
  #
  # There is no systemd-resolved here to disable -- `networking.systemd-resolved`
  # is not an option in this nixpkgs:
  #
  #   error: The option `networking.systemd-resolved' does not exist.
  #
  # Turning resolvconf off was NOT sufficient on its own. `networking.nameservers`
  # is consumed BY resolvconf; with resolvconf disabled nothing writes
  # /etc/resolv.conf at all, and the container came up with NO resolv.conf:
  #
  #   cat: /etc/resolv.conf: No such file or directory
  #
  # Every lookup then failed, including through the working tunnel. The previous
  # comment here claimed "with resolvconf disabled and nameservers set to PIA's,
  # /etc/resolv.conf contains only those" -- the opposite of what happens.
  #
  # Writing the file here rather than re-enabling resolvconf is deliberate.
  # resolvconf MERGES with whatever DHCP hands out, and this container gets
  # 10.0.0.1 from the Incus bridge that way. A sibling instance shows the result:
  #
  #   nameserver 192.168.178.1     <- configured
  #   nameserver 10.0.0.1          <- injected by DHCP on incusbr0
  #
  # so re-enabling resolvconf would hand the one container that must not leak a
  # resolver that is reachable over eth0. Owning the file outright keeps the
  # resolver set to exactly PIA's two.
  #
  # These two options are the supported pairing: nixpkgs asserts they are not
  # both set, and that assertion only applies when resolvconf is enabled.
  networking.resolvconf.enable = false;
  environment.etc."resolv.conf".text = ''
    nameserver ${builtins.head piaDns}
    nameserver ${builtins.elemAt piaDns 1}
    options edns0
  '';

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
      # Wait for the rendered secrets to exist before reading them.
      #
      # These files are written by the HOST, by incus/apply.sh, into a directory
      # mounted into this container. That can happen either side of the
      # container's own boot, and on a cold `incus start` the unit wins the race:
      #
      #   03:34:46  pre-start: /var/lib/incus-secrets/pia-username: No such file
      #   03:34:46  qb-openvpn: Main process exited, status=1/FAILURE
      #   03:34:47  apply.sh writes pia-username and pia-password   <- 1.5s too late
      #
      # OpenVPN then has no credentials, and there is no point proceeding. Wait
      # for both files rather than failing, and wait for them to be non-empty so
      # a half-written file is not read as an empty credential.
      #
      # Bounded so a genuinely missing secret still fails loudly instead of
      # hanging the unit forever; the failure mode is then a clear timeout rather
      # than a tunnel that silently never comes up.
      waited=0
      while :; do
        if [ -s /var/lib/incus-secrets/pia-username ] \
           && [ -s /var/lib/incus-secrets/pia-password ]; then
          break
        fi
        if [ "$waited" -ge 120 ]; then
          echo "pia credentials not present after $waited s -- check renderedSecrets in ./incus.nix and that incus/apply.sh rendered them" >&2
          exit 1
        fi
        sleep 1
        waited=$((waited + 1))
      done

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
      # `uidrange`, NOT `from`. `ip rule`'s `from` selector takes an address or
      # a prefix, never a uid, so the original form was rejected outright:
      #
      #   Error: any valid prefix is expected rather than "996".
      #
      # That failure was not cosmetic. It aborted postStart AFTER OpenVPN had
      # already authenticated and brought tun0 up, so systemd tore the tunnel
      # straight back down -- and the rules were never installed. qBittorrent
      # was left running with no kill-switch at all, which is the one state this
      # whole file exists to prevent. Measured in that state, uid 996 reached the
      # internet over eth0 unauthenticated.
      #
      # `ip rule add uidrange 996-996` is the uid selector; a single uid is
      # expressed as the degenerate range uid-uid.
      #
      # The rules themselves belong to qb-killswitch.service and are normally
      # already installed by the time this runs. Added here only as a repair, and
      # deliberately WITHOUT the delete-then-add that this used to do: that
      # opened a window in which neither rule existed, which is precisely the
      # leaking state. `ip rule add` fails harmlessly with "File exists" when the
      # rule is already present, and the confirmation grep below is what
      # actually decides whether the kill-switch is in place.
      for dns in ${lib.concatStringsSep " " piaDns}; do
        ip rule add pref 80 to "$dns" lookup "${vpnTable}" 2>/dev/null || true
      done
      ip rule add pref 90 to ${lanSubnet} lookup main 2>/dev/null || true
      ip rule add pref 100 uidrange "${qbUid}-${qbUid}" lookup "${vpnTable}" 2>/dev/null || true
      ip rule add pref 101 uidrange "${qbUid}-${qbUid}" unreachable 2>/dev/null || true

      # `lookup 51820` — the table NUMBER. `ip rule` expects a number here,
      # unlike `ip route ... table <n>` which takes either. Both are the bare
      # number; the earlier attempt quoted it and produced:
      #
      #   error: cannot coerce an integer to a string: 51820
      #
      # This route is what pref 100 resolves to. It lives and dies with tun0:
      # when the device goes, the route goes with it, pref 100 stops matching,
      # and traffic falls to pref 101.
      ip route replace default dev tun0 table "${vpnTable}"

      # Echo the two rules back so `systemctl status` shows what is actually
      # installed. If this prints nothing, the kill-switch is NOT in place and
      # qBittorrent traffic would fall through to eth0.
      #
      # `ip -brief rule show` does NOT print the word "pref"; it prints the
      # priority as a bare field, like `100:`. The previous grep looked for
      # "pref 100" and therefore matched nothing EVEN WHEN THE RULES WERE
      # INSTALLED -- a confirmation that could only ever report failure, which
      # is worse than none. Anchor on the priority field instead.
      ip -brief rule show | grep -E "^(80|90|100|101):"
    '';

    postStop = ''
      # Deliberately does NOT remove the kill-switch rules.
      #
      # It used to, and that was a leak, not a cleanup. Stopping the tunnel
      # deleted pref 100 and pref 101, which left qBittorrent running with no
      # confinement at all. Measured on this host in exactly that state:
      #
      #   qb-openvpn: inactive, tun0: gone, rules: []
      #   uid 996 egress: 217.224.110.155   <- the home ISP, unencrypted
      #
      # A kill-switch that switches itself off when the thing it protects goes
      # down is worse than none, because it looks armed until you test it.
      #
      # Nothing needs tidying here either: the pref-100 route lives in the
      # kernel and is torn down with tun0 automatically. The rules stay, the
      # route goes, pref 100 stops matching, and traffic falls to pref 101 --
      # unreachable. That is the intended behaviour, reached by the tunnel
      # disappearing rather than by anyone deleting a rule.
      #
      # The rules are owned by qb-killswitch.service below.
    '';
  };

  # ---------------------------------------------------------------------------
  # THE KILL-SWITCH, as its own unit
  # ---------------------------------------------------------------------------
  #
  # These rules used to be installed by qb-openvpn's postStart and removed by its
  # postStop. That couples the kill-switch's lifetime to the tunnel's lifetime,
  # which is precisely backwards: the rules have to outlive the tunnel, because
  # the moment the tunnel drops is the moment they start mattering.
  #
  # So they get their own unit, wanted at boot and independent of OpenVPN. It
  # runs early, arms both rules, and stays armed. Fail-closed from the first
  # moment of boot: until tun0 exists, pref 100 finds no route and pref 101
  # makes uid 996 unreachable, which is the correct state for a container whose
  # entire purpose is not to leak.
  systemd.services.qb-killswitch = {
    description = "Arm the qBittorrent kill-switch (blocks uid ${qbUid} unless tun0 is up)";
    wantedBy = [ "multi-user.target" ];
    before = [ "qbittorrent.service" ];

    path = [
      pkgs.iproute2
      pkgs.coreutils
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;

      # Installing a rule needs CAP_NET_ADMIN, same as configuring tun. Granted
      # to this one-shot and not to qBittorrent.
      AmbientCapabilities = [ "CAP_NET_ADMIN" ];
      CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
      NoNewPrivileges = true;

      # Only on an explicit stop of THIS unit. qb-openvpn stopping does not run
      # it, which is the whole point.
      #
      # ExecStop rather than postStop: postStop also fires when the unit fails
      # or is restarted, and disarming the kill-switch on a failure is the
      # opposite of what should happen.
      ExecStop = ''
        ip rule del pref 80 2>/dev/null || true
        ip rule del pref 90 2>/dev/null || true
        ip rule del pref 100 2>/dev/null || true
        ip rule del pref 101 2>/dev/null || true
      '';
    };

    # `script`, NOT serviceConfig.ExecStart.
    #
    # ExecStart is parsed by systemd, which takes the FIRST TOKEN of the first
    # line as the executable path. A leading comment therefore becomes the
    # program to run, and the unit dies before touching any rule:
    #
    #   Process: 245 ExecStart=# Add-if-missing, never delete-then-add: ...
    #   Unable to locate executable '#': No such file or directory
    #   Failed at step EXEC spawning #: status=203/EXEC
    #
    # `script` wraps the text in a generated shell script with a real shebang,
    # which is why `preStart`/`postStart` elsewhere in this file can open with a
    # comment and work. Do not "simplify" this back to ExecStart.
    script = ''
      # PIA's resolvers FIRST, at pref 80, ahead of the LAN bypass below.
      #
      # This is a direct consequence of a mistake in the previous revision. PIA's
      # resolvers are 10.0.0.243 and 10.0.0.242, which fall INSIDE the
      # 10.0.0.0/24 bridge subnet. So the LAN bypass below swallowed DNS queries
      # and sent them out eth0 to an address that does not exist on this LAN:
      #
      #   ip route get 10.0.0.243  (uid 996)  ->  dev eth0 src 10.0.0.112
      #
      # Every lookup then timed out, trackers could not be resolved, and
      # qBittorrent showed the flame icon with the torrent interface bound
      # correctly to tun0. The tunnel was up the whole time and the egress IP
      # was correct -- only name resolution was broken, which is exactly what
      # makes this easy to misdiagnose as a peer/connectivity problem.
      #
      # Routing the resolvers to the VPN table explicitly, at a lower pref than
      # the bypass, is the fix. Lower pref is evaluated first, so DNS wins over
      # the LAN rule while ordinary LAN traffic still bypasses.
      for dns in ${lib.concatStringsSep " " piaDns}; do
        ip rule add pref 80 to "$dns" lookup "${vpnTable}" 2>/dev/null || true
      done

      # LAN bypass, evaluated BEFORE the uid rules (pref 90 < 100).
      #
      # Without this the kill-switch captures its own control plane: qBittorrent's
      # REPLY to a WebUI request also originates from uid 996, so it matched
      # pref 100 and was sent out tun0 to PIA instead of back to Caddy on the
      # bridge. Measured on this host:
      #
      #   ip route get 10.0.0.1   (root)  -> dev eth0  src 10.0.0.112
      #   ip route get 10.0.0.1   (uid 996) -> dev tun0 table 51820 src 10.133.0.13
      #
      # and the symptom was the WebUI answering HTTP 200 on 127.0.0.1:8080 while
      # the host's connection to 10.0.0.112:8080 hung with no response and no
      # RST. Adding this rule made the host connect immediately.
      #
      # This is not a leak. The bridge is L2 on this host and nothing in this
      # container forwards to the internet, so traffic to ${lanSubnet} cannot
      # reach an ISP. It is the same carve-out every split-tunnel VPN config
      # makes for the local network.
      ip rule add pref 90 to ${lanSubnet} lookup main 2>/dev/null || true

      # Add-if-missing, never delete-then-add: there must be no instant during
      # boot when neither rule exists.
      ip rule add pref 100 uidrange "${qbUid}-${qbUid}" lookup "${vpnTable}" 2>/dev/null || true
      ip rule add pref 101 uidrange "${qbUid}-${qbUid}" unreachable          2>/dev/null || true

      # Fail loudly at boot rather than silently running disarmed. `ip rule add`
      # above tolerates "File exists", so this is the only thing that can catch
      # a rule that genuinely failed to install.
      missing=0
      for pref in 80 90 100 101; do
        if ip -brief rule show | grep -qE "^$pref:"; then
          echo "kill-switch rule pref $pref: armed"
        else
          echo "kill-switch rule pref $pref: MISSING -- uid ${qbUid} is NOT confined" >&2
          missing=1
        fi
      done
      exit $missing
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

  # Ordering: qBittorrent after the tunnel AND after the kill-switch.
  #
  # Requires qb-killswitch, Wants qb-openvpn. The asymmetry is deliberate.
  #
  # The kill-switch is security-critical: if it cannot arm, uid 996 is not
  # confined, so qBittorrent must not run. `Requires`.
  #
  # The tunnel is NOT security-critical, because the kill-switch already makes a
  # missing tunnel safe -- pref 100 stops matching when tun0 goes, and traffic
  # falls to pref 101, unreachable. So `Wants` is correct: qBittorrent starts,
  # can reach no peer and no tracker, and leaks nothing. Refusing to start would
  # be worse UX for no security gain.
  #
  # An earlier version used `Requires` for BOTH, which turned a transient tunnel
  # failure into a dead torrent client. `Requires` does not restart the dependent
  # when the requirement later recovers, so one failed start left qBittorrent
  # dead indefinitely while the tunnel came back fine:
  #
  #   03:34:46  qb-openvpn: Main process exited, status=1/FAILURE
  #   03:34:57  qbittorrent: Job failed with result 'dependency'
  #   03:35:07  qb-openvpn restarted and succeeded -- qbittorrent stayed dead
  systemd.services.qbittorrent = {
    after = [
      "qb-openvpn.service"
      "qb-killswitch.service"
    ];
    requires = [ "qb-killswitch.service" ];
    wants = [ "qb-openvpn.service" ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/qbittorrent/temp 0750 ${qbUser} media -"
  ];
}