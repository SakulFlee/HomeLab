let
  pkgs = import (import ./nixpkgs.nix) { };
in
{
  network = {
    inherit pkgs;
    description = "HomeLab";
    ordering = {
      tags = [
        "ddns"
        "web"
        "svc"
      ];
    };
  };

  "cf-ddns" = _: {
    deployment.tags = [ "ddns" ];
    system.stateVersion = "25.05";

    # Disabling SystemD units that don't work inside LXC
    systemd.suppressedSystemUnits = [
      "dev-mqueue.mount"
      "sys-kernel-debug.mount"
      "sys-fs-fuse-connections.mount"
    ];
    systemd.mounts = [
      {
        where = "/sys/kernel/debug";
        enable = false;
      }
      {
        where = "/sys/kernel/config";
        enable = false;
      }
    ];

    # LXC Containers don't boot
    boot.loader.grub.enable = false;

    fileSystems."/" = {
      device = "none";
      fsType = "rootfs";
      options = [ "rw" "relatime" ];
    };

    networking.firewall.enable = true;

    environment.systemPackages = with pkgs; [
      neovim
    ];

    services.openssh = {
      enable = true;
      openFirewall = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
    };

    users.users.root.openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC+/nVLDx7H/NeQJ82RsCdnckDPt8v+4kdhM1j6ThKoKORn+y8wg3mTAp/vfsX73gBrX/7JGbIjL2Revl3p1pJ00EAVFcnDifAlx3PRYhTKnE0Mwik65rjlbTghDjFbsyWsnyTJef2LIRxzlq7uhmAWPd4Ft5rQBEJ62mUGhXXG+9GmUJO26OQm1kkdeBgN3ctLjyesS61NJpnjs/CgMFG62LQEAmBahW2IplwayEvkITqVqQ09/un9UjTnvF1+UZbtZIzzgAhjAxa72LARz4FuBDnHjta5ukQjJdtStDBhlDUoFJlsgjaYg5Ho/ICILFCTd/+UZXh3lk0oAAU7GUULIzoY/JNcFMooI2IkR3Cvpumq2oYMNDn5M6+eTTbP7TvLl0V123bVGCzEq08MRIze072ybh9IfZpZAKow0YilE2ndBPcMhiv+dXi9PQ281on+PFv8bVwWgLl/kEeI9vJTT5MwVX02DLLOBI04Zts8n+HyQNDnrqsUj4XBR+9zFDs= github-actions@pve" ];

    users.users.user = {
      isNormalUser = true;
      extraGroups = [ "wheel" "networkmanager" ];
      openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC+/nVLDx7H/NeQJ82RsCdnckDPt8v+4kdhM1j6ThKoKORn+y8wg3mTAp/vfsX73gBrX/7JGbIjL2Revl3p1pJ00EAVFcnDifAlx3PRYhTKnE0Mwik65rjlbTghDjFbsyWsnyTJef2LIRxzlq7uhmAWPd4Ft5rQBEJ62mUGhXXG+9GmUJO26OQm1kkdeBgN3ctLjyesS61NJpnjs/CgMFG62LQEAmBahW2IplwayEvkITqVqQ09/un9UjTnvF1+UZbtZIzzgAhjAxa72LARz4FuBDnHjta5ukQjJdtStDBhlDUoFJlsgjaYg5Ho/ICILFCTd/+UZXh3lk0oAAU7GUULIzoY/JNcFMooI2IkR3Cvpumq2oYMNDn5M6+eTTbP7TvLl0V123bVGCzEq08MRIze072ybh9IfZpZAKow0YilE2ndBPcMhiv+dXi9PQ281on+PFv8bVwWgLl/kEeI9vJTT5MwVX02DLLOBI04Zts8n+HyQNDnrqsUj4XBR+9zFDs= github-actions@pve" ];
    };
  };

  "caddy" = _: {
    deployment.tags = [ "web" ];
    system.stateVersion = "25.05";

    # Disabling SystemD units that don't work inside LXC
    systemd.suppressedSystemUnits = [
      "dev-mqueue.mount"
      "sys-kernel-debug.mount"
      "sys-fs-fuse-connections.mount"
    ];
    systemd.mounts = [
      {
        where = "/sys/kernel/debug";
        enable = false;
      }
      {
        where = "/sys/kernel/config";
        enable = false;
      }
    ];

    # LXC Containers don't boot
    boot.loader.grub.enable = false;

    fileSystems."/" = {
      device = "none";
      fsType = "rootfs";
      options = [ "rw" "relatime" ];
    };

    networking.firewall.enable = true;

    environment.systemPackages = with pkgs; [
      neovim
    ];

    services.openssh = {
      enable = true;
      openFirewall = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
    };

    users.users.root.openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC+/nVLDx7H/NeQJ82RsCdnckDPt8v+4kdhM1j6ThKoKORn+y8wg3mTAp/vfsX73gBrX/7JGbIjL2Revl3p1pJ00EAVFcnDifAlx3PRYhTKnE0Mwik65rjlbTghDjFbsyWsnyTJef2LIRxzlq7uhmAWPd4Ft5rQBEJ62mUGhXXG+9GmUJO26OQm1kkdeBgN3ctLjyesS61NJpnjs/CgMFG62LQEAmBahW2IplwayEvkITqVqQ09/un9UjTnvF1+UZbtZIzzgAhjAxa72LARz4FuBDnHjta5ukQjJdtStDBhlDUoFJlsgjaYg5Ho/ICILFCTd/+UZXh3lk0oAAU7GUULIzoY/JNcFMooI2IkR3Cvpumq2oYMNDn5M6+eTTbP7TvLl0V123bVGCzEq08MRIze072ybh9IfZpZAKow0YilE2ndBPcMhiv+dXi9PQ281on+PFv8bVwWgLl/kEeI9vJTT5MwVX02DLLOBI04Zts8n+HyQNDnrqsUj4XBR+9zFDs= github-actions@pve" ];

    users.users.user = {
      isNormalUser = true;
      extraGroups = [ "wheel" "networkmanager" ];
      openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC+/nVLDx7H/NeQJ82RsCdnckDPt8v+4kdhM1j6ThKoKORn+y8wg3mTAp/vfsX73gBrX/7JGbIjL2Revl3p1pJ00EAVFcnDifAlx3PRYhTKnE0Mwik65rjlbTghDjFbsyWsnyTJef2LIRxzlq7uhmAWPd4Ft5rQBEJ62mUGhXXG+9GmUJO26OQm1kkdeBgN3ctLjyesS61NJpnjs/CgMFG62LQEAmBahW2IplwayEvkITqVqQ09/un9UjTnvF1+UZbtZIzzgAhjAxa72LARz4FuBDnHjta5ukQjJdtStDBhlDUoFJlsgjaYg5Ho/ICILFCTd/+UZXh3lk0oAAU7GUULIzoY/JNcFMooI2IkR3Cvpumq2oYMNDn5M6+eTTbP7TvLl0V123bVGCzEq08MRIze072ybh9IfZpZAKow0YilE2ndBPcMhiv+dXi9PQ281on+PFv8bVwWgLl/kEeI9vJTT5MwVX02DLLOBI04Zts8n+HyQNDnrqsUj4XBR+9zFDs= github-actions@pve" ];
    };
  };

  "syncthing" = _: {
    deployment.tags = [ "svc" ];
    system.stateVersion = "25.05";

    # Disabling SystemD units that don't work inside LXC
    systemd.suppressedSystemUnits = [
      "dev-mqueue.mount"
      "sys-kernel-debug.mount"
      "sys-fs-fuse-connections.mount"
    ];
    systemd.mounts = [
      {
        where = "/sys/kernel/debug";
        enable = false;
      }
      {
        where = "/sys/kernel/config";
        enable = false;
      }
    ];

    # LXC Containers don't boot
    boot.loader.grub.enable = false;

    fileSystems."/" = {
      device = "none";
      fsType = "rootfs";
      options = [ "rw" "relatime" ];
    };

    networking.firewall.enable = true;

    environment.systemPackages = with pkgs; [
      neovim
    ];

    services.openssh = {
      enable = true;
      openFirewall = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
    };

    users.users.root.openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC+/nVLDx7H/NeQJ82RsCdnckDPt8v+4kdhM1j6ThKoKORn+y8wg3mTAp/vfsX73gBrX/7JGbIjL2Revl3p1pJ00EAVFcnDifAlx3PRYhTKnE0Mwik65rjlbTghDjFbsyWsnyTJef2LIRxzlq7uhmAWPd4Ft5rQBEJ62mUGhXXG+9GmUJO26OQm1kkdeBgN3ctLjyesS61NJpnjs/CgMFG62LQEAmBahW2IplwayEvkITqVqQ09/un9UjTnvF1+UZbtZIzzgAhjAxa72LARz4FuBDnHjta5ukQjJdtStDBhlDUoFJlsgjaYg5Ho/ICILFCTd/+UZXh3lk0oAAU7GUULIzoY/JNcFMooI2IkR3Cvpumq2oYMNDn5M6+eTTbP7TvLl0V123bVGCzEq08MRIze072ybh9IfZpZAKow0YilE2ndBPcMhiv+dXi9PQ281on+PFv8bVwWgLl/kEeI9vJTT5MwVX02DLLOBI04Zts8n+HyQNDnrqsUj4XBR+9zFDs= github-actions@pve" ];

    users.users.user = {
      isNormalUser = true;
      extraGroups = [ "wheel" "networkmanager" ];
      openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC+/nVLDx7H/NeQJ82RsCdnckDPt8v+4kdhM1j6ThKoKORn+y8wg3mTAp/vfsX73gBrX/7JGbIjL2Revl3p1pJ00EAVFcnDifAlx3PRYhTKnE0Mwik65rjlbTghDjFbsyWsnyTJef2LIRxzlq7uhmAWPd4Ft5rQBEJ62mUGhXXG+9GmUJO26OQm1kkdeBgN3ctLjyesS61NJpnjs/CgMFG62LQEAmBahW2IplwayEvkITqVqQ09/un9UjTnvF1+UZbtZIzzgAhjAxa72LARz4FuBDnHjta5ukQjJdtStDBhlDUoFJlsgjaYg5Ho/ICILFCTd/+UZXh3lk0oAAU7GUULIzoY/JNcFMooI2IkR3Cvpumq2oYMNDn5M6+eTTbP7TvLl0V123bVGCzEq08MRIze072ybh9IfZpZAKow0YilE2ndBPcMhiv+dXi9PQ281on+PFv8bVwWgLl/kEeI9vJTT5MwVX02DLLOBI04Zts8n+HyQNDnrqsUj4XBR+9zFDs= github-actions@pve" ];
    };
  };

  "minecraft" = _: {
    deployment.tags = [ "svc" ];
    system.stateVersion = "25.05";

    # Disabling SystemD units that don't work inside LXC
    systemd.suppressedSystemUnits = [
      "dev-mqueue.mount"
      "sys-kernel-debug.mount"
      "sys-fs-fuse-connections.mount"
    ];
    systemd.mounts = [
      {
        where = "/sys/kernel/debug";
        enable = false;
      }
      {
        where = "/sys/kernel/config";
        enable = false;
      }
    ];

    # LXC Containers don't boot
    boot.loader.grub.enable = false;

    fileSystems."/" = {
      device = "none";
      fsType = "rootfs";
      options = [ "rw" "relatime" ];
    };

    networking.firewall.enable = true;

    environment.systemPackages = with pkgs; [
      neovim
    ];

    services.openssh = {
      enable = true;
      openFirewall = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
    };

    users.users.root.openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC+/nVLDx7H/NeQJ82RsCdnckDPt8v+4kdhM1j6ThKoKORn+y8wg3mTAp/vfsX73gBrX/7JGbIjL2Revl3p1pJ00EAVFcnDifAlx3PRYhTKnE0Mwik65rjlbTghDjFbsyWsnyTJef2LIRxzlq7uhmAWPd4Ft5rQBEJ62mUGhXXG+9GmUJO26OQm1kkdeBgN3ctLjyesS61NJpnjs/CgMFG62LQEAmBahW2IplwayEvkITqVqQ09/un9UjTnvF1+UZbtZIzzgAhjAxa72LARz4FuBDnHjta5ukQjJdtStDBhlDUoFJlsgjaYg5Ho/ICILFCTd/+UZXh3lk0oAAU7GUULIzoY/JNcFMooI2IkR3Cvpumq2oYMNDn5M6+eTTbP7TvLl0V123bVGCzEq08MRIze072ybh9IfZpZAKow0YilE2ndBPcMhiv+dXi9PQ281on+PFv8bVwWgLl/kEeI9vJTT5MwVX02DLLOBI04Zts8n+HyQNDnrqsUj4XBR+9zFDs= github-actions@pve" ];

    users.users.user = {
      isNormalUser = true;
      extraGroups = [ "wheel" "networkmanager" ];
      openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC+/nVLDx7H/NeQJ82RsCdnckDPt8v+4kdhM1j6ThKoKORn+y8wg3mTAp/vfsX73gBrX/7JGbIjL2Revl3p1pJ00EAVFcnDifAlx3PRYhTKnE0Mwik65rjlbTghDjFbsyWsnyTJef2LIRxzlq7uhmAWPd4Ft5rQBEJ62mUGhXXG+9GmUJO26OQm1kkdeBgN3ctLjyesS61NJpnjs/CgMFG62LQEAmBahW2IplwayEvkITqVqQ09/un9UjTnvF1+UZbtZIzzgAhjAxa72LARz4FuBDnHjta5ukQjJdtStDBhlDUoFJlsgjaYg5Ho/ICILFCTd/+UZXh3lk0oAAU7GUULIzoY/JNcFMooI2IkR3Cvpumq2oYMNDn5M6+eTTbP7TvLl0V123bVGCzEq08MRIze072ybh9IfZpZAKow0YilE2ndBPcMhiv+dXi9PQ281on+PFv8bVwWgLl/kEeI9vJTT5MwVX02DLLOBI04Zts8n+HyQNDnrqsUj4XBR+9zFDs= github-actions@pve" ];
    };
  };
}
