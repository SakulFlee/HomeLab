{ lib, ... }:
let
  podmanGateway = "10.88.0.1";
in {
  systemd.tmpfiles.settings."bitmagnet" = {
    "/var/lib/bitmagnet/config"."d" = {
      mode = "0755";
      user = "root";
      group = "root";
    };
    "/var/lib/bitmagnet/data"."d" = {
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
      containers.bitmagnet = {
        image = "ghcr.io/bitmagnet-io/bitmagnet:latest";
        dependsOn = [ "gluetun" ];
        extraOptions = [ "--network=container:gluetun" ];
        environment = {
          POSTGRES_HOST = podmanGateway;
          POSTGRES_PORT = "5432";
          POSTGRES_DB = "bitmagnet";
          POSTGRES_USER = "bitmagnet";
          POSTGRES_PASSWORD = "bitmagnet";
          LOG_LEVEL = "info";
        };
        volumes = [
          "/var/lib/bitmagnet/config:/root/.config/bitmagnet"
          "/var/lib/bitmagnet/data:/root/.local/share/bitmagnet"
        ];
        cmd = [
          "worker"
          "run"
          "--keys=http_server,queue_server,dht_crawler"
        ];
      };
    };
  };

  services.homelab-restic = {
    enable = true;
    paths = [
      "/var/lib/bitmagnet/config"
      "/var/lib/bitmagnet/data"
    ];
  };
}
