{ ... }: {
  services.sonarr = {
    enable = true;
  };

  # Allow sonarr to access NAS media shares
  users.users.sonarr.extraGroups = [ "media" ];
}
