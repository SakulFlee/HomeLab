{ config, pkgs, ... }:
let
  updateScript = pkgs.writeShellScript "cloudflare-ddns" ''
    set -euo pipefail

    API_TOKEN=$(cat ${config.sops.secrets.cloudflare_api_token.path})
    ZONE_ID=$(cat ${config.sops.secrets.cloudflare_zone_id.path})
    DOMAINS=$(cat ${config.sops.secrets.cloudflare_domains.path})

    IP=$(curl -sf https://ipv4.icanhazip.com)
    [ -z "$IP" ] && { echo "Failed to get public IP"; exit 1; }

    for DOMAIN in $DOMAINS; do
      RECORD=$(curl -sf -H "Authorization: Bearer $API_TOKEN" \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$DOMAIN" | \
        ${pkgs.jq}/bin/jq -r '.result[0] // empty')

      [ -z "$RECORD" ] && { echo "No A record found for $DOMAIN"; continue; }

      RECORD_ID=$(echo "$RECORD" | ${pkgs.jq}/bin/jq -r '.id')
      CURRENT_IP=$(echo "$RECORD" | ${pkgs.jq}/bin/jq -r '.content')

      if [ "$CURRENT_IP" != "$IP" ]; then
        echo "Updating $DOMAIN: $CURRENT_IP → $IP"
        curl -sf -X PATCH \
          -H "Authorization: Bearer $API_TOKEN" \
          -H "Content-Type: application/json" \
          -d "{\"content\":\"$IP\",\"name\":\"$DOMAIN\",\"type\":\"A\",\"ttl\":120}" \
          "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" >/dev/null
      else
        echo "$DOMAIN already set to $IP"
      fi
    done
  '';
in {
  sops.secrets = {
    cloudflare_api_token = {};
    cloudflare_zone_id = {};
    cloudflare_domains = {};
  };

  environment.systemPackages = with pkgs; [ curl jq ];

  systemd.services.cloudflare-ddns = {
    description = "Cloudflare DDNS updater";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [ curl jq ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${updateScript}";
    };
  };

  systemd.timers.cloudflare-ddns = {
    description = "Cloudflare DDNS update timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
      RandomizedDelaySec = "30s";
    };
  };
}
