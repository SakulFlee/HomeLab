{ config, ... }: {
  services.technitium-dns-server = {
    enable = true;
    openFirewall = true;
  };

  # Technitium defaults to logging in /var/log/technitium, but the module
  # uses ProtectSystem = "strict" which makes that read-only. This tells
  # systemd to create the directory and give the DynamicUser write access.
  systemd.services.technitium-dns-server.serviceConfig = {
    LogsDirectory = "technitium";
  };

  services.restic-backup = {
    enable = true;
    paths = [ "/var/lib/technitium-dns-server/" ];
  };
}
