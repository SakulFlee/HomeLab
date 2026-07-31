{ ... }:
{
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # mdns resolution
  system.nssDatabases.hosts = [ "files" "mdns_minimal [NOTFOUND=return]" "dns" "mdns" ];
}
