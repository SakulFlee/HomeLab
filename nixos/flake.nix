{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    
    plasma-manager = {
      url = "github:pjones/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    llama-cpp = {
      url = "github:ggml-org/llama.cpp";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixvim = {
      url = "github:nix-community/nixvim/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    fansly-recorder = {
      url = "github:SakulFlee/FanslyRecorder";
    };

    hermes-agent = {
      url = "github:NousResearch/hermes-agent";
    };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    crane = {
      url = "github:ipetkov/crane";
    };

    nix-flatpak = {
      url = "github:gmodena/nix-flatpak";
    };

    sudo-tee-opencode-nvim = {
      url = "github:sudo-tee/opencode.nvim";
      flake = false;
    };

    jovian = {
      url = "github:Jovian-Experiments/Jovian-NixOS";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

    outputs = { self, nixpkgs, home-manager, nixvim, nix-flatpak, jovian, ... }@inputs: 
    let    
      system = "x86_64-linux";

      sharedArgs = {
        inherit inputs home-manager;
      };
    in {
      nixosConfigurations = {
      Evil-Donkey = nixpkgs.lib.nixosSystem {
        specialArgs = sharedArgs;
        modules = [
          { nixpkgs.hostPlatform = system; }
          ./hosts/evil-donkey/configuration.nix 
        ];
      };

      Cindry = nixpkgs.lib.nixosSystem {
        specialArgs = sharedArgs;
        modules = [
          { nixpkgs.hostPlatform = system; }
          ./hosts/cindry/configuration.nix 
        ];
      };

      SteamDeck = nixpkgs.lib.nixosSystem {
        specialArgs = sharedArgs;
        modules = [
          { nixpkgs.hostPlatform = system; }
          ./hosts/steamdeck/configuration.nix 
        ];
      };

      HomeLab = nixpkgs.lib.nixosSystem {
        specialArgs = sharedArgs;
        modules = [
          { nixpkgs.hostPlatform = system; }
          ./hosts/homelab/configuration.nix 
        ];
      };
    };
  };
}
