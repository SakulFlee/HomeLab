{ config, pkgs, lib, ... }: {
  services.prometheus = {
    enable = true;
    port = 9090;
    listenAddress = "127.0.0.1";
    scrapeConfigs = [
      {
        job_name = "node";
        static_configs = [{ targets = [ "127.0.0.1:9100" ]; }];
      }
      {
        job_name = "caddy";
        static_configs = [{ targets = [ "127.0.0.1:2019" ]; }];
      }
      {
        job_name = "forgejo";
        static_configs = [{ targets = [ "127.0.0.1:3002" ]; }];
      }
      {
        job_name = "postgres";
        static_configs = [{ targets = [ "127.0.0.1:9187" ]; }];
      }
    ];
    exporters.node = {
      enable = true;
      enabledCollectors = [ "systemd" "hwmon" ];
      port = 9100;
      listenAddress = "127.0.0.1";
    };
  };

  # Grafana — dashboards
  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "127.0.0.1";
        http_port = 3003;
        domain = "grafana.sakul-flee.de";
        root_url = "https://grafana.sakul-flee.de";
      };
      "auth.anonymous".enabled = false;
      security = {
        admin_user = "admin";
        secret_key = "placeholder-overridden-by-env";
      };
      analytics = {
        reporting_enabled = false;
      };
    };
    provision = {
      enable = true;
      datasources.settings.datasources = [{
        name = "Prometheus";
        type = "prometheus";
        url = "http://127.0.0.1:9090";
        access = "proxy";
        isDefault = true;
        jsonData.timeInterval = "1m";
      }];
      dashboards.settings.providers = [{
        name = "HomeLab";
        options.path = "/etc/grafana/provisioning/dashboards";
      }];
    };
  };

  # Generate a random Grafana secret key on first start
  systemd.services.grafana.preStart = ''
    if [ ! -f /var/lib/grafana/secret_key ]; then
      umask 077
      echo "GRAFANA_SECRET_KEY=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c40)" > /var/lib/grafana/secret_key
    fi
  '';
  systemd.services.grafana.serviceConfig.EnvironmentFile = "-/var/lib/grafana/secret_key";

  networking.firewall.allowedTCPPorts = [ 3003 ];

  # PostgreSQL exporter (runs as a systemd service)
  systemd.services.postgres-exporter = {
    description = "Prometheus PostgreSQL Exporter";
    after = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.prometheus-postgres-exporter}/bin/postgres_exporter \
        --web.listen-address=127.0.0.1:9187 \
        --data-source-name=postgresql://postgres@/postgres?host=/run/postgresql";
      Restart = "on-failure";
      User = "postgres";
    };
  };
}
