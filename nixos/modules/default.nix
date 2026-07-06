{ ... }: {
  imports = [
    ./proxmox-lxc.nix
    ./auto-update.nix
    ./sops.nix
    ./dns.nix
  ];
}
