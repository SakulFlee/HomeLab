{ config, ... }: {
  nixpkgs.overlays = [
    (final: prev: {
      libmsquic = prev.libmsquic.overrideAttrs (old: {
        buildInputs = builtins.filter
          (p: p.pname or "" != "lttng-tools")
          (old.buildInputs or []);
      });
    })
  ];

  services.technitium-dns-server = {
    enable = true;
    openFirewall = true;
  };

  systemd.services.technitium-dns-server = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    environment = {
      DOTNET_USE_POLLING_FILE_WATCHER = "true";
    };
  };

  systemd.services.technitium-dns-server.serviceConfig = {
    LogsDirectory = "technitium";
  };

  services.homelab-restic = {
    enable = true;
    paths = [ "/var/lib/private/technitium-dns-server/" ];
  };
}
