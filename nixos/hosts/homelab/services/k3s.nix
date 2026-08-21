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
    # Image GC thresholds act as a capacity backstop; the k3s-image-prune timer
    # (below) proactively removes unused images so the thresholds stay high.
    extraFlags = ''
      --resolv-conf /etc/k3s-resolv.conf
      --kubelet-arg=image-gc-high-threshold=85
      --kubelet-arg=image-gc-low-threshold=75
    '';
  };

  # Proactively prune containerd images not referenced by any running container,
  # regardless of disk capacity. crictl ships with the k3s package.
  systemd.services.k3s-image-prune = {
    description = "Prune unused k3s containerd images";
    after = [ "k3s.service" ];
    wants = [ "k3s.service" ];
    path = with pkgs; [ k3s ];
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      crictl --runtime-endpoint unix:///run/k3s/containerd/containerd.sock rmi --prune || true
    '';
  };

  systemd.timers.k3s-image-prune = {
    description = "Weekly prune of unused k3s containerd images";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
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
