{ ... }: {
  virtualisation.podman = {
    enable = true;
  };

  virtualisation.oci-containers = {
    backend = "podman";
    containers.website = {
      image = "forgejo.sakul-flee.de/sakulflee/website:latest";
      ports = [ "127.0.0.1:8081:80" ];
      autoStart = true;
    };
  };
}
