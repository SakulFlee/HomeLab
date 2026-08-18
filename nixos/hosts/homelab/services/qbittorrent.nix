{ config, pkgs, lib, ... }:
let
  qbConfig = "/var/lib/qbittorrent/config/qBittorrent/qBittorrent.conf";

  portMonitor = pkgs.writeShellScript "pia-port-monitor" ''
    QB_CONFIG="${qbConfig}"
    CHECK_INTERVAL=300
    DEFAULT_PORT=6881

    log() { echo "[pia-port-monitor] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }

    while true; do
      PORT=$(${pkgs.podman}/bin/podman exec gluetun cat /tmp/gluetun/forwarded_port 2>/dev/null || echo "none")

      if [[ "$PORT" != "none" ]] && [[ "$PORT" != "null" ]]; then
        QB_PORT=$(grep -E "^Session\\Port=" "$QB_CONFIG" 2>/dev/null | cut -d'=' -f2 | tr -d '\r')
        if [[ "$QB_PORT" != "$PORT" ]]; then
          log "Port changed: $QB_PORT -> $PORT"
          sed -i "s/^Session\\Port=.*/Session\\Port=$PORT/" "$QB_CONFIG"
          ${pkgs.systemd}/bin/systemctl restart podman-qbittorrent
        fi
      fi

      sleep "$CHECK_INTERVAL"
    done
  '';
in {
  systemd.tmpfiles.settings."qbittorrent" = {
    "/var/lib/qbittorrent/config"."d" = {
      mode = "0755";
      user = "root";
      group = "root";
    };
  };

  virtualisation = {
    podman = {
      enable = true;
    };
    oci-containers = {
      backend = "podman";
      containers.qbittorrent = {
          image = "lscr.io/linuxserver/qbittorrent:latest";
          dependsOn = [ "gluetun" ];
          extraOptions = [ "--network=container:gluetun" ];
          environment = {
            PUID = "1000";
            PGID = "1000";
            UMASK = "002";
            WEBUI_PORT = "8080";
          };
          volumes = [
            "/var/lib/qbittorrent/config:/config"
            "/mnt/nas/qBittorrent:/mnt/nas/qBittorrent"
            "/mnt/nas/Shows:/mnt/nas/Shows"
            "/mnt/nas/Movies:/mnt/nas/Movies"
            "/mnt/nas/NSFW:/mnt/nas/NSFW"
          ];
        };
      };
    };
  systemd.services.pia-port-monitor = {
    description = "PIA Port Forwarding Monitor for qBittorrent";
    after = [ "podman-gluetun.service" "podman-qbittorrent.service" ];
    wants = [ "podman-gluetun.service" "podman-qbittorrent.service" ];
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [ podman gnused systemd ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${portMonitor}";
      Restart = "always";
      RestartSec = 10;
    };
  };
}
