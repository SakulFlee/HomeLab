{ ... }: {
  services.radarr = {
    enable = true;
  };

  # Allow radarr to access NAS media shares
  users.users.radarr.extraGroups = [ "media" ];

  services.homelab-restic = {
    enable = true;
    paths = [ "/var/lib/radarr" ];
  };
}
