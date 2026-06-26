{ config, pkgs, sops-nix, ... }: {
  imports = [ sops-nix.nixosModules.sops ];

  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
}
