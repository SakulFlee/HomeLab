{
  description = "HomeLab NixOS container configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, sops-nix }: {
    nixosConfigurations.caddy = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit sops-nix; };
      modules = [ ./hosts/caddy ];
    };

    nixosConfigurations.website = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit sops-nix; };
      modules = [ ./hosts/website ];
    };

    nixosConfigurations.forgejo = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit sops-nix; };
      modules = [ ./hosts/forgejo ];
    };

    nixosConfigurations.woodpecker = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit sops-nix; };
      modules = [ ./hosts/woodpecker ];
    };
  };
}
