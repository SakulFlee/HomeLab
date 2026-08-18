{ config, lib, pkgs, ... }: {
  sops.secrets."k3s-token" = {};

  services.k3s = {
    enable = true;
    role = "server";
    tokenFile = config.sops.secrets."k3s-token".path;
    # Phase 1: no k8s ingresses yet. Traefik will be enabled on non-standard
    # ports in a later phase when the first apps (website/syncthing) land.
    #
    # Point pod DNS at our own resolv.conf (router first, Technitium fallback).
    # The host /etc/resolv.conf has nameserver 127.0.0.1 which is unusable
    # inside pods; without this k3s substitutes public DNS (8.8.8.8).
    extraFlags = "--disable=traefik --resolv-conf /etc/k3s-resolv.conf";
  };

  environment.etc."k3s-resolv.conf".text = ''
    nameserver 192.168.178.1
    nameserver 192.168.178.200
  '';

  environment.systemPackages = with pkgs; [ kubectl ];

  # k3s API server, kubelet, and (future) Traefik non-standard ports
  networking.firewall.allowedTCPPorts = [ 6443 10250 8080 8443 ];
  # Flannel VXLAN (8472/udp) for pod-to-pod across nodes
  networking.firewall.allowedUDPPorts = [ 8472 ];
  # Allow forwarding between the pod bridge (cni0) and the LAN (eno1).
  # Without this, flannel pod traffic is dropped by the firewall.
  networking.firewall.extraForwardRules = ''
    iifname "cni0" oifname "eno1" accept
    iifname "eno1" oifname "cni0" accept
  '';
  # Reverse-path filtering breaks VXLAN return traffic
  networking.firewall.checkReversePath = false;

  # Masquerade pod traffic (cni0) out of the LAN so the router can route replies back.
  # Merges with wg0/podman NAT from the wireguard module.
  networking.nat.internalInterfaces = [ "cni0" ];
}
