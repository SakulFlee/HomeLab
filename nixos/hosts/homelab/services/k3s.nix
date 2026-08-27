{ config, lib, pkgs, ... }: {
  sops.secrets."k3s-token" = {};

  services.k3s = {
    enable = true;
    role = "server";
    tokenFile = config.sops.secrets."k3s-token".path;
    # Disable the bundled local-path addon: it owns the 'local-path' StorageClass
    # (re-created on every restart) and its default annotation. We provide our
    # own local-path-provisioner and storage classes (see apps/storage-class).
    disable = [ "local-storage" ];
    # Traefik (k3s-bundled) is the ingress layer serving 80/443. Point pod DNS
    # at the router. The host /etc/resolv.conf uses the router as its resolver,
    # but the pod's own resolv.conf needs an explicit nameserver.
    # Image GC thresholds act as a capacity backstop; the k3s-image-prune timer
    # (below) proactively removes unused images so the thresholds stay high.
    extraFlags = ''
      --resolv-conf /etc/k3s-resolv.conf
      --kubelet-arg=image-gc-high-threshold=85
      --kubelet-arg=image-gc-low-threshold=75
    '';
  };

  # The storage mount is noauto (see hardware.nix), so switch-to-configuration
  # never tries to unmount/remount it while k3s/containerd hold the path busy
  # (which hung rebuilds at "restarting sysinit-reactivation.target").
  # Order k3s after the mount unit and mount it explicitly here on k3s start.
  systemd.services.k3s.after = [ "var-lib-rancher-k3s-storage.mount" ];
  systemd.services.k3s.preStart = ''
    mkdir -p /var/lib/rancher/k3s/storage
    ${pkgs.util-linux}/bin/mountpoint -q /var/lib/rancher/k3s/storage || ${pkgs.util-linux}/bin/mount /var/lib/rancher/k3s/storage
  '';

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
  '';

  environment.systemPackages = with pkgs; [ kubectl ];

  # NixOS firewall is disabled host-wide (see configuration.nix); k3s/flannel
  # manages its own nftables rules for pod networking. Only the NAT masquerade
  # for pod egress (cni0 -> LAN) is configured here.
  networking.nat.internalInterfaces = [ "cni0" ];
}
