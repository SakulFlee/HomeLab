{
  description = "A basic Morph-managed NixOS container";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable"; # Or a specific stable channel like "nixos-24.05"
    morph.url = "github:NixOS/morph";
  };

  outputs = { self, nixpkgs, morph, ... }: {
    morphHosts = {
      # Define your host(s) here. You can add more hosts as needed.
      caddy = {
        # Specify the type of host. For a Proxmox LXC, 'lxc' is appropriate.
        # Morph might interact with the Proxmox API directly, or you might
        # still manage the LXC creation through Proxmox and then use Morph
        # to deploy the NixOS configuration *inside* the LXC.
        # This example assumes you'll deploy *into* an existing LXC.
        type = "lxc"; # Or "nixos" for a regular NixOS machine

        # The NixOS configuration for this host
        config = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux"; # Adjust if your LXC architecture is different
          specialArgs = { inherit self; }; # Pass flake inputs if needed

          modules = [
            # Your original NixOS configuration
            ({ config, modulesPath, pkgs, lib, ... }: {
              imports = [ (modulesPath + "/virtualisation/proxmox-lxc.nix") ];
              system.stateVersion = "25.05";

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

              users.users.root.openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC+/nVLDx7H/NeQJ82RsCdnckDPt8v+4kdhM1j6ThKoKORn+y8wg3mTAp/vfsX73gBrX/7JGbIjL2Revl3p1pJ00EAVFcnDifAlx3PRYhTKnE0Mwik65rjlbTghDjFbsyTJef2LIRxzlq7uhmAWPd4Ft5rQBEJ62mUGhXXG+9GmUJO26OQm1kkdeBgN3ctLjyesS61NJpnjs/CgMFG62LQEAmBahW2IplwayEvkITqVqQ09/un9UjTnvF1+UZbtZIzzgAhjAxa72LARz4FuBDnHjta5ukQjJdtStDBhlDUoFJlsgjaYg5Ho/ICILFCTd/+UZXh3lk0oAAU7GUULIzoY/JNcFMooI2IkR3Cvpumq2oYMNDn5M6+eTTbP7TvLl0V123bVGCzEq08MRIze072ybh9IfZpZAKow0YilE2ndBPcMhiv+dXi9PQ281on+PFv8bVwWgLl/kEeI9vJTT5MwVX02DLLOBI04Zts8n+HyQNDnrqsUj4XBR+9zFDs= github-actions@pve" ];

              users.users.user = {
                isNormalUser  = true;
                extraGroups  = [ "wheel" "networkmanager" ];
                openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC+/nVLDx7H/NeQJ82RsCdnckDPt8v+4kdhM1j6ThKoKORn+y8wg3mTAp/vfsX73gBrX/7JGbIjL2Revl3p1pJ00EAVFcnDifAlx3PRYhTKnE0Mwik65rjlbTghDjFbsyWsnyTJef2LIRxzlq7uhmAWPd4Ft5rQBEJ62mUGhXXG+9GmUJO26OQm1kkdeBgN3ctLjyesS61NJpnjs/CgMFG62LQEAmBahW2IplwayEvkITqVqQ09/un9UjTnvF1+UZbtZIzzgAhjAxa72LARz4FuBDnHjta5ukQjJdtStDBhlDUoFJlsgjaYg5Ho/ICILFCTd/+UZXh3lk0oAAU7GUULIzoY/JNcFMooI2IkR3Cvpumq2oYMNDn5M6+eTTbP7TvLl0V123bVGCzEq08MRIze072ybh9IfZpZAKow0YilE2ndBPcMhiv+dXi9PQ281on+PFv8bWl/kEeI9vJTT5MwVX02DLLOBI04Zts8n+HyQNDnrqsUj4XBR+9zFDs= github-actions@pve" ];
              };
            })
          ];
        };
      };
    };
  };
}
