{
  description = "HomeLab NixOS container configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    fansly-recorder = {
      url = "git+https://forgejo.sakul-flee.de/SakulFlee/FanslyRecorder.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, sops-nix, fansly-recorder }: {
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

    nixosConfigurations.renovate = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit sops-nix; };
      modules = [ ./hosts/renovate ];
    };

    nixosConfigurations.minecraft = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit sops-nix; };
      modules = [ ./hosts/minecraft ];
    };

    nixosConfigurations.hytale = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit sops-nix; };
      modules = [ ./hosts/hytale ];
    };

    nixosConfigurations.jellyfin = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit sops-nix; };
      modules = [ ./hosts/jellyfin ];
    };

    nixosConfigurations.prowlarr = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit sops-nix; };
      modules = [ ./hosts/prowlarr ];
    };

    nixosConfigurations.sonarr = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit sops-nix; };
      modules = [ ./hosts/sonarr ];
    };

    nixosConfigurations.radarr = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit sops-nix; };
      modules = [ ./hosts/radarr ];
    };

    nixosConfigurations.qbittorrent = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit sops-nix; };
      modules = [ ./hosts/qbittorrent ];
    };

    nixosConfigurations.fansly-recorder = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit sops-nix fansly-recorder; };
      modules = [ ./hosts/fansly-recorder ];
    };

    nixosConfigurations.wireguard = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit sops-nix; };
      modules = [ ./hosts/wireguard ];
    };
  };
}
