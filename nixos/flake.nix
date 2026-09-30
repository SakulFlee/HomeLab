{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, ... }@inputs:
    let
      system = "x86_64-linux";

      # A NixOS system container destined for an Incus instance.
      #
      # The lxc-container module is what provides system.build.squashfs (the
      # rootfs image) and system.build.metadata (the tarball holding the image
      # metadata). incus/apply.sh feeds both to `incus image import`.
      #
      # These are separate from HomeLab below: HomeLab is the bare-metal host
      # and is never rebuilt as a container image.
      mkInstance = instancePath: nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          ({ lib, ... }: {
            nixpkgs.hostPlatform = system;

            # Not a bootloader target: an LXC shares the host kernel.
            boot.loader.grub.enable = false;
            # No swap device inside a container.
            swapDevices = [ ];
            # Match the host so scheduled things line up.
            time.timeZone = "Europe/Berlin";

            # -------------------------------------------------
            # Strip what lxc-container.nix pulls in by default.
            #
            # It transitively imports minimal.nix, channel.nix and
            # clone-config.nix, and turns documentation back on with
            # mkOverride 890 (chosen only to beat minimal.nix's mkDefault).
            # For a service container that is dead weight:
            #
            #   documentation.enable / documentation.nixos.enable
            #     man pages plus the full NixOS manual.
            #   nix.channel.enable  nix-channel, the pre-flake mechanism.
            #     Unused here and confusing sitting next to a flake.
            #
            # mkForce (priority 50) beats mkOverride 890 outright, so these
            # win regardless of module ordering.
            # -------------------------------------------------
            documentation.enable = lib.mkForce false;
            documentation.nixos.enable = lib.mkForce false;
            nix.channel.enable = lib.mkForce false;
            nix.autoOptimiseStore = lib.mkForce false;
            nix.settings.auto-optimise = lib.mkForce false;

            # Nix itself stays enabled: it is what makes `nix build` inside the
            # instance (and any ad-hoc `nix run`) possible. What is disabled
            # above is the channel machinery, not the package manager.

            # -------------------------------------------------
            # Same two overrides that need `lib`, kept here rather than in a
            # separate module so the whole "make this container minimal"
            # story reads as one block.
            #
            # lxc-instance-common.nix sets root's initial password to the empty
            # string (mkOverride 150) and prints a getty hint telling you so.
            # These instances have no SSH and no exposed console, but an empty
            # root password is not something to inherit quietly. Lock the
            # account: `incus exec` goes through the API and does not care.
            # -------------------------------------------------
            users.users.root.initialHashedPassword = lib.mkForce "!";
            users.users.root.password = null;

            # services.openssh is mkDefault true in that module. Instances are
            # reached with `incus exec` and nothing forwards port 22, so an
            # sshd that is never started is just extra surface.
            services.openssh.enable = lib.mkForce false;
            services.openssh.startWhenNeeded = lib.mkForce false;
          }
          "${nixpkgs}/nixos/modules/virtualisation/lxc-container.nix"
          instancePath
        ];
      };
    in
    {
      nixosConfigurations = {
        # The bare-metal host.
        HomeLab = nixpkgs.lib.nixosSystem {
          specialArgs = { inherit inputs; };
          modules = [
            { nixpkgs.hostPlatform = system; }
            ./hosts/homelab/configuration.nix
          ];
        };

        # Incus instances. Build with:
        #   nix build .#nixosConfigurations.<name>.config.system.build.squashfs
        caddy = mkInstance ./hosts/caddy;
        forgejo = mkInstance ./hosts/forgejo;
      };

      # Convenience: buildable images, so `nix build .#image-<name>` works.
      packages.${system} = {
        image-caddy = self.nixosConfigurations.caddy.config.system.build.squashfs;
        image-forgejo = self.nixosConfigurations.forgejo.config.system.build.squashfs;
      };
    };
}