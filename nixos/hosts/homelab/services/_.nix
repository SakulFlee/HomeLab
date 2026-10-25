{ lib, ... }: {
  imports = [
    ./forgejo-nix-runner.nix
    ./incus-image-gc.nix
    ./incus.nix
    ./incus-secrets.nix
    ./ttyd.nix
  ];
}
