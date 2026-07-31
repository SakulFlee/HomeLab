{ config, pkgs, ... }: {
  systemd.tmpfiles.rules = [
    "d /var/log/caddy 0755 caddy caddy -"
    "d /var/lib/private 0700 root root -"
  ];

  systemd.services.crowdsec.serviceConfig = {
    StateDirectory = "crowdsec";
    StateDirectoryMode = "0700";
  };

  services.crowdsec = {
    enable = true;

    settings.general.api.server.enable = true;
    settings.general.api.server.listen_uri = "127.0.0.1:8088";
    settings.lapi.credentialsFile = "/var/lib/crowdsec/state/lapi-api-key.yaml";
    settings.capi.credentialsFile = "/var/lib/crowdsec/state/capi-api-key.yaml";
    settings.general.api.server.console_path = "/var/lib/crowdsec/state/console.yaml";

    localConfig.acquisitions = [
      {
        source = "journalctl";
        journalctl_filter = [ "_SYSTEMD_UNIT=sshd.service" ];
        labels = {
          type = "syslog";
        };
      }
      {
        source = "file";
        filenames = [ "/var/log/caddy/access.log" ];
        labels = {
          type = "caddy";
        };
      }
    ];

    localConfig.parsers.s02Enrich = [
      {
        name = "homelab/whitelist";
        description = "Whitelist home LAN and VPN networks";
        whitelist = {
          reason = "Trusted internal networks";
          cidr = [
            "192.168.178.0/24"
            "10.100.0.0/24"
          ];
        };
      }
    ];

    hub.collections = [ "crowdsecurity/linux" ];
    hub.parsers = [ "crowdsecurity/caddy-logs" ];
  };

  sops.secrets."crowdsec_key" = {};

  services.crowdsec-firewall-bouncer = {
    enable = true;
    registerBouncer.enable = false;
    secrets.apiKeyPath = config.sops.secrets."crowdsec_key".path;
  };
}
