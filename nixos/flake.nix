{
  inputs = {
    # A release branch, not nixpkgs-unstable.
    #
    # Forgejo is the reason, and it is a hard constraint rather than a
    # preference. The k3s deployment runs forgejo:16-rootless with
    # pullPolicy: Always and is in fact on 16.0.5, which is what produced the
    # database dump being restored. Forgejo's schema migrations only ever run
    # forwards, so the binary must not be older than the data -- and on
    # nixpkgs-unstable it was 16.0.0, whose Go (1.26.4) is below the
    # `toolchain go1.26.5` that 16.0.5 requires. Go then discards the vendor
    # tree and re-resolves, giving "inconsistent vendoring" from both
    # directions. No choice of vendorHash fixes that.
    #
    # nixos-26.05 carries forgejo 16.0.5 and the Go to build it, so the version
    # that matters is correct by construction instead of by override. See
    # pkgs/forgejo.nix for what that removed.
    #
    # The cost is deliberate: future nixpkgs updates are no longer a plain
    # `nix-update` of a moving ref, they are a re-pin of this branch.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, ... }@inputs:
    let
      system = "x86_64-linux";

      # A NixOS system destined for an Incus instance: a container or a VM.
      #
      # kind = "container"
      #   lxc-container.nix provides system.build.squashfs (the rootfs image)
      #   and system.build.metadata (the tarball holding the image metadata).
      #   incus/apply.sh feeds both to `incus image import`, metadata first.
      #
      # kind = "vm"
      #   incus-virtual-machine.nix provides system.build.qemuImage, a single
      #   qcow2-compressed disk. One artefact, so `incus image import` gets one
      #   argument rather than two. That module also brings its own EFI
      #   partition, systemd-boot, growPartition and serial console, so a VM
      #   needs none of the bootloader surgery a container needs.
      #
      # These are separate from HomeLab below: HomeLab is the bare-metal host
      # and is never rebuilt as an instance image.
      mkInstance =
        { path, kind ? "container" }:
        nixpkgs.lib.nixosSystem {
          specialArgs = { inherit inputs; };
          modules = [
            (
              { lib, ... }: {
                nixpkgs.hostPlatform = system;

                # Match the host so scheduled things line up.
                time.timeZone = "Europe/Berlin";

                # Pinned explicitly: without this the eval warns and defaults
                # to the current release. It is the *config* format version,
                # not the NixOS release, so it moves rarely and on purpose.
                system.stateVersion = "25.11";

                # -------------------------------------------------
                # Strip what lxc-instance-common.nix pulls in by default. It is
                # imported by BOTH lxc-container.nix and
                # incus-virtual-machine.nix, so these apply to VMs as well:
                #
                #   documentation.enable / documentation.nixos.enable
                #     man pages plus the full NixOS manual.
                #   nix.channel.enable  nix-channel, the pre-flake mechanism.
                #     Unused here and confusing sitting next to a flake.
                #
                # mkForce (priority 50) beats mkOverride 890 outright.
                #
                # Do NOT try to disable auto-optimisation here. It was
                # tempting (nix.autoOptimiseStore, then
                # nix.settings.auto-optimise), but both spellings write a key
                # that Nix 2.34 rejects:
                #   error: unknown setting 'auto-optimise'
                # and it only ever applied to single-user installs anyway.
                # -------------------------------------------------
                documentation.enable = lib.mkForce false;
                documentation.nixos.enable = lib.mkForce false;
                nix.channel.enable = lib.mkForce false;

                # Nix itself stays enabled: it is what makes `nix build` inside
                # the instance possible. What is disabled above is the channel
                # machinery, not the package manager.

                # -------------------------------------------------
                # lxc-instance-common.nix sets root's initial password to the
                # empty string (mkOverride 150) and prints a getty hint telling
                # you so. An empty root password is not something to inherit
                # quietly. Lock the account: `incus exec` goes through the API
                # and does not care.
                #
                # For a VM this costs the `incus console` login prompt, which
                # is why a VM also gets sshd below: it has a real network and
                # should not be reachable only through the API.
                # -------------------------------------------------
                users.users.root.initialHashedPassword = lib.mkForce "!";
                users.users.root.password = null;

                # Container-only. A VM boots from a real bootloader and runs its
                # own kernel, so none of this applies to it.
                } // lib.optionalAttrs (kind == "container") {
                  # Not a bootloader target: an LXC shares the host kernel.
                  boot.loader.grub.enable = false;
                  # No swap device inside a container.
                  swapDevices = [ ];

                  # services.openssh is mkDefault true in that module, and for most
                  # containers that is the wrong default: they are reached with
                  # `incus exec` and nothing forwards port 22, so an sshd that
                  # never starts is just extra surface.
                  #
                  # The forgejo container is the exception and opts back in, in its
                  # own ./hosts/forgejo/ssh.nix. Git transport must be served by an
                  # sshd *inside* that container, because `forgejo serv` only runs
                  # as RUN_USER -- see that file for the argument.
                  #
                  # Priority 990, which is the whole point of the change and is
                  # worth being explicit about.
                  #
                  # nixpkgs sets this option twice already:
                  #   lxc-instance-common.nix   services.openssh.enable = lib.mkDefault true;
                  #   the openssh module itself sets a default too
                  # Both are mkDefault (1000). Two definitions at the same priority
                  # are an error, not a merge:
                  #
                  #   Definition values:
                  #   - In `.../flake.nix': false
                  #     Use `lib.mkForce value` or `lib.mkDefault value` to change the priority
                  #
                  # So mkDefault cannot be used here, and mkForce would be wrong:
                  # mkForce beats a plain `services.openssh.enable = true` in the
                  # instance, which would make hosts/forgejo/ssh.nix unable to
                  # re-enable it.
                  #
                  # 990 sits above both upstream mkDefaults and below an explicit
                  # definition in the instance (plain = 100), which is exactly the
                  # precedence this wants: off by default here, and any instance
                  # that sets the option to true for itself wins.
                  services.openssh =
                    let
                      # 990 beats both upstream mkDefaults (1000) and loses to a
                      # plain definition in the instance (100), so an instance that
                      # wants sshd can still have it.
                      disabled = lib.mkOverride 990 false;
                    in
                    {
                      enable = disabled;
                      startWhenNeeded = disabled;
                    };
                }
            )
            (
              if kind == "vm" then
                "${nixpkgs}/nixos/modules/virtualisation/incus-virtual-machine.nix"
              else
                "${nixpkgs}/nixos/modules/virtualisation/lxc-container.nix"
            )
            path
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
        caddy = mkInstance { path = ./hosts/caddy; };
        forgejo = mkInstance { path = ./hosts/forgejo; };
        wireguard = mkInstance { path = ./hosts/wireguard; kind = "vm"; };
        # A VM: it runs the Forgejo Actions runner with a Docker
        # daemon inside the guest (see hosts/forgejo-runner/default.nix
        # for why that needs a kernel of its own).
        forgejo-runner = mkInstance { path = ./hosts/forgejo-runner; kind = "vm"; };
      };

      # Convenience: buildable images, so `nix build .#image-<name>` works.
      packages.${system} = {
        image-caddy = self.nixosConfigurations.caddy.config.system.build.squashfs;
        image-forgejo = self.nixosConfigurations.forgejo.config.system.build.squashfs;

        # A VM is one qcow2 disk rather than a rootfs plus a metadata tarball.
        image-wireguard = self.nixosConfigurations.wireguard.config.system.build.qemuImage;
        image-forgejo-runner = self.nixosConfigurations.forgejo-runner.config.system.build.qemuImage;
      };

      # The Incus-level half of each instance: limits, volumes, devices. Plain
      # data, not a NixOS config, so incus/apply.sh can read it with
      #
      #   nix eval --json .#incusInstances.caddy
      #
      # without evaluating a whole system. Keeping it as an output (rather than
      # parsing nixos/incus-instances.nix in shell) means the script and the
      # host's systemd units can never disagree about what an instance is.
      incusInstances = import ./incus-instances.nix;

        # Which Incus project each instance lives in, so incus/apply.sh can pass
        # the right --project per instance:
        #
        #   nix eval --raw .#incusInstanceProjects.forgejo
        #
        # Separate from incusInstances because it is keyed the same way but
        # answers a different question, and `--all` has to consult it once per
        # instance: apply.sh takes a single --project per invocation, so a set
        # spanning two projects cannot be reconciled in one run -- and
        # incus-reconcile.timer runs `--all` every fifteen minutes precisely so
        # that nothing is left waiting on a human.
        #
        # An instance absent from this map is in Incus's `default` project.
        incusInstanceProjects = import ./incus-instance-projects.nix;

        # The shape of each Incus project this host owns, keyed by PROJECT name:
        #
        #   nix eval --json .#incusProjects.forgejo
        #
        # Presence in this map is what makes incus/apply.sh create the project,
        # and the keys under it are applied as project config. A third output
        # rather than a second field on incusInstanceProjects because the two
        # answer different questions and have different keys: instances name the
        # project they live in, and a project outlives the instances placed in
        # it.
        #
        # This has to live here at all because the nixpkgs `incus` module has no
        # `projects` option -- `storage_pools` applies to `default` only -- so
        # without it a project exists solely because someone typed
        # `incus project create` into a live Incus once.
        incusProjects = import ./incus-projects.nix;
    };
}