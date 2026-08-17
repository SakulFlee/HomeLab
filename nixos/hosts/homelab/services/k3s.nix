{ config, lib, pkgs, ... }: {
  sops.secrets."k3s-token" = {};

  services.k3s = {
    enable = true;
    role = "server";
    tokenFile = config.sops.secrets."k3s-token".path;
    # Phase 1: no k8s ingresses yet. Traefik will be enabled on non-standard
    # ports in a later phase when the first apps (website/syncthing) land.
    extraFlags = "--disable=traefik";
  };

  environment.systemPackages = with pkgs; [ kubectl ];

  # k3s API server, kubelet, and (future) Traefik non-standard ports
  networking.firewall.allowedTCPPorts = [ 6443 10250 8080 8443 ];
}
