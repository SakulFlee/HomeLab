{ config, pkgs, ... }: {
  virtualisation.podman = {
    enable = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  virtualisation.oci-containers = {
    backend = "podman";
    containers.website = {
      image = "forgejo.sakul-flee.de/sakulflee/website:latest";
      ports = [ "80:80" ];
      autoStart = true;
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
