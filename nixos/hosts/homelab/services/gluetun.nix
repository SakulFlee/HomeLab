{ config, pkgs, ... }: {
  sops.secrets."vpn_pia_username" = {};
  sops.secrets."vpn_pia_password" = {};

  systemd.tmpfiles.settings."gluetun" = {
    "/var/lib/gluetun"."d" = {
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
      containers.gluetun = {
        image = "qmcgaw/gluetun:latest";
        ports = [
          "3333:3333/tcp"
          "3334:3334/tcp"
          "3334:3334/udp"
          "8080:8080/tcp"
        ];
        environment = {
          VPN_SERVICE_PROVIDER = "private internet access";
          VPN_TYPE = "openvpn";
          PORT_FORWARDING = "on";
          HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE = "{\"auth\":\"none\"}";
        };
        environmentFiles = [ "/run/gluetun/env" ];
        extraOptions = [ "--cap-add=NET_ADMIN" "--cap-add=NET_RAW" "--device=/dev/net/tun" ];
        volumes = [ "/var/lib/gluetun:/gluetun" ];
      };
    };
  };

  systemd.services."podman-gluetun" = {
    after = [ "network.target" ];
    path = with pkgs; [ gnused ];
    serviceConfig.ExecStartPre = [
      (let
        script = pkgs.writeShellScript "gluetun-env-pre" ''
          mkdir -p /run/gluetun
          USER=$(cat ${config.sops.secrets.vpn_pia_username.path})
          PASS=$(cat ${config.sops.secrets.vpn_pia_password.path})
          echo "OPENVPN_USER=$USER" > /run/gluetun/env
          echo "OPENVPN_PASSWORD=$PASS" >> /run/gluetun/env
        '';
      in "${script}")
    ];
  };
}
