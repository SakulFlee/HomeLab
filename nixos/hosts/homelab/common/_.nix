{ ... }: {
  imports = [
    ./sops.nix
    ./restic.nix
    ./backup.nix
    ./dns.nix
    ./subvolumes.nix
  ];
}
