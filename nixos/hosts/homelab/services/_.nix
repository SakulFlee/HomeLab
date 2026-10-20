{ lib, ... }: {
  imports = [
    ./incus-image-gc.nix
    ./incus.nix
    ./incus-secrets.nix
    ./ttyd.nix
  ];
}
