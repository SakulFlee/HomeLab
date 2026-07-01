{ config, pkgs, lib, ... }:
let
  qbConfig = "/var/lib/qbittorrent/config/qBittorrent/qBittorrent.conf";

  portMonitor = pkgs.writeShellScript "pia-port-monitor" ''
    QB_CONFIG="${qbConfig}"
    CHECK_INTERVAL=300
    DEFAULT_PORT=6881

    log() { echo "[pia-port-monitor] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }

    while true; do
      PORT=$(curl -sf http://localhost:8000/v1/openvpn/port-forwarded || echo "none")

      if [[ "$PORT" != "none" ]] && [[ "$PORT" != "null" ]]; then
        QB_PORT=$(grep -E "^Session\\\\Port=" "$QB_CONFIG" 2>/dev/null | cut -d'=' -f2 | tr -d '\r')
        if [[ "$QB_PORT" != "$PORT" ]]; then
          log "Port changed: $QB_PORT -> $PORT"
          sed -i "s/^Session\\\\Port=.*/Session\\\\Port=$PORT/" "$QB_CONFIG"
          ${pkgs.podman}/bin/podman restart qbittorrent
        fi
      fi

      sleep "$CHECK_INTERVAL"
    done
  '';
in {
  imports = [
    ../../modules
  ];

  sops.secrets."vpn_pia_username" = {
    sopsFile = ../../secrets/general.sops.yaml;
  };
  sops.secrets."vpn_pia_password" = {
    sopsFile = ../../secrets/general.sops.yaml;
  };

  virtualisation = {
    podman = {
      enable = true;
      defaultNetwork.settings.dns_enabled = true;
    };
    oci-containers = {
      backend = "podman";
      containers = {
        gluetun = {
          image = "qmcgaw/gluetun:latest";
          ports = [
            "8000:8000/tcp"
            "8080:8080/tcp"
          ];
          environment = {
            VPN_SERVICE_PROVIDER = "private internet access";
            VPN_TYPE = "openvpn";
            PORT_FORWARDING = "on";
          };
          environmentFiles = [ "/run/gluetun/env" ];
          extraOptions = [ "--cap-add=NET_ADMIN" ];
          volumes = [ "/var/lib/gluetun:/gluetun" ];
        };
        qbittorrent = {
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
            "/mnt/nas/qbittorrent:/downloads"
            "/mnt/nas/music:/music"
            "/mnt/nas/shows:/shows"
            "/mnt/nas/movies:/movies"
            "/mnt/nas/nsfw:/nsfw"
          ];
        };
      };
    };
  };

  systemd.services.gluetun-env = {
    description = "Generate gluetun env file from sops secrets";
    requiredBy = [ "podman-gluetun.service" ];
    before = [ "podman-gluetun.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /run/gluetun
      echo "OPENVPN_USER=$(cat ${config.sops.secrets.vpn_pia_username.path})" > /run/gluetun/env
      echo "OPENVPN_PASSWORD=$(cat ${config.sops.secrets.vpn_pia_password.path})" >> /run/gluetun/env
    '';
  };

  systemd.services.pia-port-monitor = {
    description = "PIA Port Forwarding Monitor for qBittorrent";
    after = [ "podman-gluetun.service" "podman-qbittorrent.service" ];
    wants = [ "podman-gluetun.service" "podman-qbittorrent.service" ];
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [ podman curl gnused ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${portMonitor}";
      Restart = "always";
      RestartSec = 10;
    };
  };
}
