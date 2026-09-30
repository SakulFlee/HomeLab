{ lib, ... }: {
  imports = [
    ./k3s.nix
    ./incus.nix
  ];
}
