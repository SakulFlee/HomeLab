{ config, lib, pkgs, ... }: {
  sops.secrets."k3s-token" = {};

  services.k3s = {
    enable = true;
    role = "server";
    tokenFile = config.sops.secrets."k3s-token".path;
    # Traefik (k3s-bundled) is the ingress layer serving 80/443. Point pod DNS
    # at our own resolv.conf (router first, Technitium fallback). The host
    # /etc/resolv.conf has nameserver 127.0.0.1 which is unusable inside pods;
    # without this k3s substitutes public DNS (8.8.8.8).
    extraFlags = "--resolv-conf /etc/k3s-resolv.conf";
  };

  environment.etc."k3s-resolv.conf".text = ''
    nameserver 192.168.178.1
    nameserver 192.168.178.200
  '';

  environment.systemPackages = with pkgs; [ kubectl ];

  # NixOS firewall is disabled host-wide (see configuration.nix); k3s/flannel
  # manages its own nftables rules for pod networking. Only the NAT masquerade
  # for pod egress (cni0 -> LAN) is configured here.
  networking.nat.internalInterfaces = [ "cni0" ];
}
