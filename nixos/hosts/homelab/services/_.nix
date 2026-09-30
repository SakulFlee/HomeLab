{ lib, ... }: {
  imports = [
    ./k3s.nix
    ./incus.nix
    ./incus-instances.nix
  ];
}
