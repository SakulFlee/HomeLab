{ config, pkgs, lib, ... }:
let
  cfg = config.services.qbittorrent;
  qbConfig = "${cfg.dataDir}/.config/qBittorrent/qBittorrent.conf";

  piaPortMonitor = pkgs.writeShellScript "pia-port-monitor" ''
    # PIA Port Forwarding Monitor for qBittorrent
    # Managed by NixOS - DO NOT EDIT MANUALLY

    QB_CONFIG="${qbConfig}"
    CHECK_INTERVAL=300
    RECONNECT_INTERVAL=60
    DEFAULT_PORT=6881
    LAST_RECONNECT_ATTEMPT=0

    log() {
      echo "[pia-port-monitor] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    }

    get_vpn_state() {
      piactl get connectionstate 2>/dev/null
    }

    get_pf_port() {
      local port
      port=$(piactl get portforward 2>/dev/null)
      if [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "$port"
      else
        echo "None"
      fi
    }

    get_qb_port() {
      if [[ -f "$QB_CONFIG" ]]; then
        local port
        port=$(grep -E "^Session\\\\Port=" "$QB_CONFIG" | cut -d'=' -f2 | tr -d '\r')
        if [[ "$port" =~ ^[0-9]+$ ]]; then
          echo "$port"
          return
        fi
      fi
      echo "None"
    }

    update_and_restart_qb() {
      local new_port=$1

      log "Stopping qBittorrent to safely update config..."
      systemctl stop qbittorrent

      sleep 2

      log "Updating qBittorrent config to port $new_port..."
      if grep -qE "^Session\\\\Port=" "$QB_CONFIG"; then
        sed -i "s/^Session\\\\Port=.*/Session\\\\Port=$new_port/" "$QB_CONFIG"
      else
        echo "Session\\Port=$new_port" >> "$QB_CONFIG"
      fi

      log "Starting qBittorrent..."
      systemctl start qbittorrent
    }

    log "Starting PIA port monitor (check interval: ${CHECK_INTERVAL}s)"

    while true; do
      state=$(get_vpn_state)

      if [[ "$state" == "Connected" ]]; then
        LAST_RECONNECT_ATTEMPT=0
        pf_port=$(get_pf_port)

        if [[ "$pf_port" != "None" ]]; then
          qb_port=$(get_qb_port)

          if [[ "$qb_port" == "None" ]]; then
            log "Warning: Could not read current port from $QB_CONFIG"
          elif [[ "$pf_port" != "$qb_port" ]]; then
            log "Port mismatch detected! PIA: $pf_port | qBittorrent: $qb_port"
            update_and_restart_qb "$pf_port"
          fi
        else
          log "VPN connected, but waiting for forwarded port..."
        fi

      elif [[ "$state" == "Disconnected" || "$state" == "Interrupted" ]]; then
        current_time=$(date +%s)

        if (( current_time - LAST_RECONNECT_ATTEMPT >= RECONNECT_INTERVAL )); then
          log "PIA VPN is down ($state). Attempting to reconnect..."
          piactl connect
          LAST_RECONNECT_ATTEMPT=$current_time
        fi

        qb_port=$(get_qb_port)
        if [[ "$qb_port" != "$DEFAULT_PORT" && "$qb_port" != "None" ]]; then
          log "VPN is down. Reverting qBittorrent to default port $DEFAULT_PORT"
          update_and_restart_qb "$DEFAULT_PORT"
        fi

      else
        log "VPN is transitioning ($state). Waiting..."
      fi

      sleep "$CHECK_INTERVAL"
    done
  '';
in {
  services.qbittorrent = {
    enable = true;
    openFirewall = true;
  };

  environment.systemPackages = with pkgs; [ piavpn ];

  systemd.services.pia-port-monitor = {
    description = "PIA Port Forwarding Monitor for qBittorrent";
    documentation = [ "https://www.privateinternetaccess.com/" ];
    after = [ "network.target" ];
    wants = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [ piavpn coreutils gnused gnugrep ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${piaPortMonitor}";
      Restart = "always";
      RestartSec = 10;
    };
  };
}
