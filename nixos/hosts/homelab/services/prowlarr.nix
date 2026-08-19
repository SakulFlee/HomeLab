{ ... }: {
  services.prowlarr = {
    enable = true;
  };

  services.homelab-restic = {
    enable = true;
    paths = [ "/var/lib/private/prowlarr" ];
  };
}
