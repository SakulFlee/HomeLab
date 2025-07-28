{ config, ... }:

{
  networking.allowedTCPPorts = [
    22 # SSH
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
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOylUlL5b8e6HIDxT7tx9Y+UWvn2QuwfkKSoROHUhbxD sakulflee@evil-donkey"
  ];
}
