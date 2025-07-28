{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ../../modules/cf-ddns/configuration.nix
  ];

  deployment.tags = [ "ddns" ];
  system.stateVersion = "25.05";

  boot.isContainer = true;
  systemd.mounts = [
    {
      where = "/sys/kernel/debug";
      enable = false;
    }
  ];
  systemd.suppressedSystemUnits = [
    "dev-mqueue.mount"
    "sys-kernel-debug.mount"
    "sys-fs-fuse-connections.mount"
  ];

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-generations";
  };
  nix.extraOptions = "auto-optimise-store = true";

  networking = {
    firewall.enable = true;
    useNetworkd = true;

    interfaces.eth0 = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = "10.0.0.100";
          prefixLength = 24; # ^/24
        }
      ];
    };

    defaultGateway = "10.0.0.1";

    nameservers = [
      "9.9.9.9"
      "149.112.112.112"
    ];
  };

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

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC+/nVLDx7H/NeQJ82RsCdnckDPt8v+4kdhM1j6ThKoKORn+y8wg3mTAp/vfsX73gBrX/7JGbIjL2Revl3p1pJ00EAVFcnDifAlx3PRYhTKnE0Mwik65rjlbTghDjFbsyWsnyTJef2LIRxzlq7uhmAWPd4Ft5rQBEJ62mUGhXXG+9GmUJO26OQm1kkdeBgN3ctLjyesS61NJpnjs/CgMFG62LQEAmBahW2IplwayEvkITqVqQ09/un9UjTnvF1+UZbtZIzzgAhjAxa72LARz4FuBDnHjta5ukQjJdtStDBhlDUoFJlsgjaYg5Ho/ICILFCTd/+UZXh3lk0oAAU7GUULIzoY/JNcFMooI2IkR3Cvpumq2oYMNDn5M6+eTTbP7TvLl0V123bVGCzEq08MRIze072ybh9IfZpZAKow0YilE2ndBPcMhiv+dXi9PQ281on+PFv8bVwWgLl/kEeI9vJTT5MwVX02DLLOBI04Zts8n+HyQNDnrqsUj4XBR+9zFDs= github-actions@pve"
  ];

  users.users.user = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC+/nVLDx7H/NeQJ82RsCdnckDPt8v+4kdhM1j6ThKoKORn+y8wg3mTAp/vfsX73gBrX/7JGbIjL2Revl3p1pJ00EAVFcnDifAlx3PRYhTKnE0Mwik65rjlbTghDjFbsyWsnyTJef2LIRxzlq7uhmAWPd4Ft5rQBEJ62mUGhXXG+9GmUJO26OQm1kkdeBgN3ctLjyesS61NJpnjs/CgMFG62LQEAmBahW2IplwayEvkITqVqQ09/un9UjTnvF1+UZbtZIzzgAhjAxa72LARz4FuBDnHjta5ukQjJdtStDBhlDUoFJlsgjaYg5Ho/ICILFCTd/+UZXh3lk0oAAU7GUULIzoY/JNcFMooI2IkR3Cvpumq2oYMNDn5M6+eTTbP7TvLl0V123bVGCzEq08MRIze072ybh9IfZpZAKow0YilE2ndBPcMhiv+dXi9PQ281on+PFv8bVwWgLl/kEeI9vJTT5MwVX02DLLOBI04Zts8n+HyQNDnrqsUj4XBR+9zFDs= github-actions@pve"
    ];
  };

  services."cloudflare-ddns".enable = true;
}
