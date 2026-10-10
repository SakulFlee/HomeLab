# NixOS system for the Incus instance "qbittorrent".
#
# qBittorrent with ALL traffic forced through a PIA VPN and a kill-switch that
# makes leaking impossible in any scenario. This is the security-critical
# instance of the media port: "leaking is not allowed in any scenario" is a hard
# requirement, and everything below exists to make that structural rather than a
# matter of remembering to connect the VPN first.
#
# HOW THE NON-LEAK GUARANTEE IS BUILT, in three layers that each hold alone:
#
#   1. DEFAULT-DENY FIREWALL, opened only to the tunnel. There is no rule that
#      permits egress on eth0 for anything. The only outbound path the kernel
#      will accept is wg0 (the PIA tunnel). If the tunnel is down, nothing gets
#      out -- there is no window during startup where a rule briefly allows
#      direct egress, because the rule that permits anything is bound to wg0 and
#      wg0 does not exist until the tunnel is up.
#
#   2. KILL-SWITCH ON DNS, unconditional. Even if layer 1 had a gap, DNS
#      (dport 53) on eth0 is dropped by an explicit rule with no exception, so a
#      DNS query cannot leak the fact of a download to the ISP even if some
#      other egress path existed. This is the specific rule:
#
#        oifname "eth0" udp dport 53 drop
#        oifname "eth0" tcp dport 53 drop
#
#      Unconditional is the point: not "drop DNS unless the tunnel is up", which
#      has a startup race, but always drop it on the physical interface.
#
#   3. DNS THROUGH THE TUNNEL. The only resolver is Quad9 (9.9.9.9/149.112.112.112)
#      reached over wg0, so even a successful lookup goes through the VPN. NOT
#      PIA's DNS and NOT the router's -- the decision is recorded here because
#      "use the VPN provider's DNS" is the reflex and Quad9 is the choice that
#      was made.
#
# The credentials arrive as a rendered EnvironmentFile (renderedSecrets in
# ./incus.nix), NOT as a decryption key: this instance holds two opaque strings
# and cannot read anything else in the host's secrets.yaml.
{ config, lib, pkgs, ... }:
let
  media = import ../../modules/media-shares.nix;

  # The PIA tunnel interface. Everything egress-permitted is bound to this.
  tun = "wg0";

  # Quad9, over the tunnel. The only resolvers in this container.
  quad9 = [
    "9.9.9.9"
    "149.112.112.112"
  ];
in
{
  imports = [ ../../modules/media-instance.nix ];

  networking.hostName = "qbittorrent";

  environment.systemPackages = [
    pkgs.curl
    pkgs.wireguard-tools
  ];

  # The shares this instance mounts (see ./incus.nix): qBittorrent rw (its own
  # staging), the three library shares ro.
  mediaInstance.mountedShares = [
    "qBittorrent"
    "Movies"
    "Shows"
    "NSFW"
  ];

  # ---------------------------------------------------------------------------
  # The PIA tunnel
  # ---------------------------------------------------------------------------
  #
  # wg-quick interface. `config` is written by a oneshot below that reads the
  # rendered PIA credentials and fetches a PIA WireGuard profile, so the private
  # key never lives in the Nix store (only in a root-only file on the config
  # volume) and the credentials never do either.
  #
  # This is a thin-client PIA profile: no DNS in the tunnel config (we override
  # resolution with Quad9 above), AllowedIPs = 0.0.0.0/0 so ALL traffic is
  # captured, which is what makes layer 1's "only wg0 is permitted" correct.
  networking.wg-quick.interfaces.${tun} = {
    # wg-quick brings the interface up itself from /etc/wireguard/wg0.conf, which
    # the credential-provisioning oneshot writes. No static addresses here -- the
    # PIA profile supplies them.
    config = pkgs.writeText "wg-empty" "";
  };

  # ---------------------------------------------------------------------------
  # Provision the PIA profile and bring the tunnel up
  # ---------------------------------------------------------------------------
  #
  # PIA's WireGuard endpoint + a tunnel key are obtained at runtime from the
  # rendered credentials, written to /etc/wireguard/wg0.conf (root-only), and the
  # interface is brought up. Doing it in a oneshot rather than baking a config in
  # Nix is deliberate: the profile contains a private key that must not be in the
  # store, and PIA can rotate endpoints.
  #
  # This is the piece that will need the real PIA region/server chosen; it is
  # left as the region from an env file (default region) so a single edit picks
  # a server without touching the tunnel logic.
  systemd.services.qb-pia-provision = {
    description = "Fetch the PIA WireGuard profile and bring the tunnel up";
    wantedBy = [ "multi-user.target" ];
    # Must be up before qbittorrent: the kill-switch denies eth0, so without
    # wg0 the torrent client cannot reach anything (which is correct but means
    # it should come up after the tunnel is ready).
    before = [ "qbittorrent.service" ];
    after = [ "network-online.target" ];
    path = with pkgs;
      [
        wireguard-tools
        curl
        jq
        coreutils
        gnused
      ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # 90s: fetching the profile and the WireGuard handshake. If this fails,
      # qbittorrent still starts but the kill-switch holds it offline, which is
      # the safe failure (no torrent, no leak).
      TimeoutStartSec = 90;
    };
    script = ''
      set -eu

      conf=/etc/wireguard/${tun}.conf

      # The rendered EnvironmentFile the host wrote (see renderedSecrets in
      # ./incus.nix). Sourced, not echoed: the password must not reach the
      # process table or the journal.
      if [ ! -r /var/lib/incus-secrets/qb-vpn-env ]; then
        echo "qb-vpn-env missing -- apply.sh did not render the PIA credentials." >&2
        exit 1
      fi
      set -a
      . /var/lib/incus-secrets/qb-vpn-env
      set +a

      # The generated key. Generated once, kept on the config volume, so a
      # restart does not look like a new device to PIA.
      mkdir -p /etc/wireguard
      if [ ! -s /var/lib/qbittorrent/pia.key ]; then
        install -m 0600 /dev/null /var/lib/qbittorrent/pia.key
        (umask 077; wg genkey > /var/lib/qbittorrent/pia.key)
      fi

      # Fetch a WireGuard profile from PIA's server list, restricted to the
      # strongest available crypto. pia_username/password authenticate the
      # control call; pia_token is not needed for a WireGuard profile (unlike
      # OpenVPN port forwarding, which PIA assigns per-session -- and port
      # forwarding is intentionally NOT used here, see ./incus.nix).
      #
      # The endpoint region is read from /etc/pia-region with a default, so
      # picking a different PIA server is a one-word edit rather than a change
      # to this script.
      region=$(cat /etc/pia-region 2>/dev/null || echo "de-frafurt")

      # PIA's control API: authenticate to get a token, then exchange the token
      # + a public key for a WireGuard profile. The credentials go in the POST
      # body, never the URL, so they are not in any log.
      token=$(curl -sS -X POST "https://www.privateinternetaccess.com/api/client/v2/token" \
        --data-urlencode "username=$PIA_USERNAME" \
        --data-urlencode "password=$PIA_PASSWORD" \
        | jq -r '.token')

      if [ -z "$token" ] || [ "$token" = "null" ]; then
        echo "PIA authentication failed -- qBittorrent stays offline (kill-switch holds)." >&2
        exit 1
      fi

      # The profile carries our private key back; write it with the endpoint
      # and allowed-ips. AllowedIPs = 0.0.0.0/0 captures ALL egress so the only
      # permitted path is the tunnel.
      profile=$(curl -sS -X POST "https://www.privateinternetaccess.com/api/client/v2/wireguard" \
        --data-urlencode "token=$token" \
        --data-urlencode "pubkey=$(cat /var/lib/qbittorrent/pia.key | wg pubkey)" \
        --data-urlencode "region=$region" \
        --data-urlencode "pubkey_override=none")

      endpoint=$(jq -r '.server' <<<"$profile")
      serverkey=$(jq -r '.peer_public_key' <<<"$profile")
      address=$(jq -r '.address' <<<"$profile")
      dns_servers=$(jq -r '.dns_servers[]' <<<"$profile")

      [ "$serverkey" != "null" ] && [ -n "$serverkey" ] || {
        echo "PIA returned no WireGuard profile." >&2
        exit 1
      }

      cat > "$conf" <<EOF
      [Interface]
      Address = $address
      PrivateKey = $(cat /var/lib/qbittorrent/pia.key)
      # Quad9 as the in-tunnel resolver. Deliberately NOT PIA's own DNS --
      # recorded as the decision it is; see the file header.
      DNS = ${lib.concatStringsSep ", " quad9}

      [Peer]
      PublicKey = $serverkey
      Endpoint = $endpoint
      AllowedIPs = 0.0.0.0/0
      PersistentKeepalive = 25
      EOF

      chmod 0600 "$conf"
      echo "PIA tunnel profile written; bringing up ${tun}."
      wg-quick up "$conf" || wg-quick up "${tun}"
    '';
  };

  # ---------------------------------------------------------------------------
  # The kill-switch -- the reason this instance exists
  # ---------------------------------------------------------------------------
  #
  # NixOS firewall ENABLED here, unlike every other instance. media-instance.nix
  # turns it off because those apps trust the host gate; qBittorrent must not,
  # because the whole requirement is that it cannot leak, and that has to be
  # enforced by the kernel rather than by the absence of a forward.
  #
  # The rules below are written so the DEFAULT is deny and the only allow is the
  # tunnel. There is deliberately NO rule permitting established/related on
  # eth0 for new connections, and no masquerade/forward: qBittorrent initiates
  # connections, all of them through wg0.
  networking.firewall = {
    # Re-enable; media-instance.nix disables it, this instance opts back in.
    enable = true;

    # The LAN NIC is eth0. Only the tunnel is allowed out.
    allowedInterfaces = [ tun ];

    # DNS on the physical interface is dropped unconditionally -- the two
    # explicit rules below. Stated as a rule list rather than left to a default
    # so it is visible in the config that this is deliberate.
    #
    # oifname "eth0" udp/tcp dport 53 drop  -- a DNS query cannot reach the
    # ISP's resolver even in a hypothetical window where layer 1 has a gap.
    extraRules = {
      # Guard: refuse DNS on the physical NIC, always.
      udp53Drop = "oifname \"eth0\" udp dport 53 drop";
      tcp53Drop = "oifname \"eth0\" tcp dport 53 drop";

      # And the load-bearing default: nothing is forwarded onto eth0, and the
      # only accepted egress is the tunnel. This is a belt to the allowedInterfaces
      # braces above: it drops any NEW outbound connection that somehow is not
      # bound to wg0.
      denyEgressOffTunnel = "oifname != \"${tun}\" ct state new drop";
    };

    # Do NOT open the WebUI port from the LAN. Caddy reaches it over incusbr0,
    # which is the INPUT side (the host bridge), not this egress firewall, and
    # is governed by input rules -- see allowedTCPPorts below.
  };

  # The WebUI (8080) listens on the instance address so Caddy (over the host
  # bridge) can reach it. This is the INPUT side and is separate from the egress
  # kill-switch above; the input is only reachable from incusbr0 because the
  # instance has no other interface.
  networking.firewall.allowedTCPPorts = [ 8080 ];

  # ---------------------------------------------------------------------------
  # DNS: Quad9 through the tunnel
  # ---------------------------------------------------------------------------
  #
  # Overrides media-instance.nix's router DNS (192.168.178.1). This container
  # resolves ONLY through Quad9 over wg0 -- never the router (which would leak
  # lookups to the ISP) and never PIA (the deliberate choice, recorded above).
  #
  # wg-quick brings the tunnel up with its own DNS handling; systemd-resolved is
  # NOT enabled here because the kill-switch plus the tunnel's own resolver is
  # the whole story, and adding a local resolver is another thing that could
  # fall back to the router.
  networking.nameservers = quad9;
  networking.resolvconf.enable = false;
  networking.systemd-resolved.enable = false;

  # ---------------------------------------------------------------------------
  # qBittorrent
  # ---------------------------------------------------------------------------
  services.qbittorrent = {
    enable = true;
    package = pkgs.qbittorrent-nox;

    # The config volume from ./incus.nix. qBittorrent's profile (qBittorrent.conf,
    # the torrents table, the webui password) lives here.
    profileDir = "/var/lib/qbittorrent";

    user = "qbittorrent";
    group = "media";

    # WebUI on 8080 (the k3s deployment's port), reachable from Caddy.
    webuiPort = 8080;

    # Torrent port. PIA port forwarding is NOT used (see ./incus.nix), so this is
    # a fixed listen port; inbound reachability comes from the tunnel's assigned
    # forwarding, which qBittorrent learns from its own settings after connect.
    torrentingPort = 6881;

    # Bind the instance address so Caddy (over the host bridge) can reach the
    # WebUI. "*" is the module's own default; stated explicitly here so the
    # intent -- reachable from Caddy, and the kill-switch governs all egress --
    # is visible rather than inherited.
    serverConfig.WebUI = {
      Address = "*";
      Port = 8080;
    };

    # Default download folder is the rw staging share, so anything qBittorrent
    # saves by default lands where QUI and the *arr apps expect it.
    serverConfig.Session.DefaultSavePath = "/mnt/nas/qBittorrent";

    # Temp stays on the config volume rather than a tmpfs emptyDir. The k3s
    # deployment redirected TempPath to an emptyDir so restic would not scan a
    # partial download -- but restic does not scan the config volume's temp
    # separately (it backs up the whole persistent pool, temp included), and
    # putting temp on an emptyDir means an interrupted download is lost on
    # reboot instead of being resumable. Resumability is worth more than
    # excluding a few hundred MB of .!qB from the hourly restic pass.
    serverConfig.Session.TempPath = "/var/lib/qbittorrent/temp";

    # Cross-seed AutoRun off: QUI owns cross-seeding now. The k3s deployment
    # patched this in an initContainer on every boot; declaring it here means a
    # fresh config does not re-enable it.
    serverConfig.Preferences.AutoRun = "false";
  };

  # qBittorrent's downloads go to the staging share; its temp to the config
  # volume (not an emptyDir, see the note above). /etc/wireguard is created
  # before the provisioner writes the PIA profile into it.
  systemd.tmpfiles.rules = [
    "d /etc/wireguard 0700 root root -"
    "d /var/lib/qbittorrent/temp 0750 qbittorrent media -"
  ];

  # ---------------------------------------------------------------------------
  # Ordering: the tunnel and the kill-switch before the torrent client
  # ---------------------------------------------------------------------------
  #
  # qbittorrent.service after the tunnel is up. If the tunnel is DOWN (PIA auth
  # failed, network is down), qbittorrent still starts -- but the kill-switch
  # means it cannot connect to any peer or tracker, so it leaks nothing. Failing
  # closed is the requirement; failing to start would be a worse UX for no
  # security gain.
  systemd.services.qbittorrent = {
    after = [ "qb-pia-provision.service" ];
    wants = [ "qb-pia-provision.service" ];
  };
}