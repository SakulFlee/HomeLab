{
  config,
  pkgs,
  lib,
  ...
}:

let
  passwordFile = builtins.readFile ./passwords/sakulflee.pass;
  passwordFileDerivation = pkgs.writeText "copyparty-password-sakulflee" settingsFile;
in
{
  deployment.tags = [ "ddns" ];

  imports = [
    ../../modules/cf-ddns/configuration.nix
    ../common/state.nix
    ../common/lxc.nix
    ../common/gc.nix
    ../common/networking.nix
    ../common/ssh.nix
    ../common/common_packages.nix

    copyparty.url = "github:9001/copyparty"
  ];

  # ensure that copyparty is an allowed argument to the outputs function
  outputs = { self, nixpkgs, copyparty }: {
    nixosConfigurations.yourHostName = nixpkgs.lib.nixosSystem {
      modules = [
        # load the copyparty NixOS module
        copyparty.nixosModules.default
        ({ pkgs, ... }: {
          # add the copyparty overlay to expose the package to the module
          nixpkgs.overlays = [ copyparty.overlays.default ];
          # (optional) install the package globally
          environment.systemPackages = [ pkgs.copyparty ];
          # configure the copyparty module
          services.copyparty.enable = true;
        })
      ];
    };
  };

  services.copyparty = {
    enable = true;

    # Directly maps to values in the [global] section of the copyparty config.
    # see `copyparty --help` for available options
    settings = {
      i = "0.0.0.0";
      p = [ 3210 ];
      
      no-reload = true;
    };

    # Create user(s) and set their password in a file
    accounts = {
      sakulflee.passwordFile = "${passwordFileDerivation}";
    };

    volumes = {
      "/" = {
        path = "/srv/copyparty";
        
        # see `copyparty --help-accounts` for available options
        access = {
          r = "";
          rw = [ "sakulflee" ];
        };
        
        # see `copyparty --help-flags` for available options
        flags = {
          # "fk" enables filekeys (necessary for upget permission) (4 chars long)
          fk = 4;

          # scan for new files every 60sec
          scan = 60;

          # volflag "e2d" enables the uploads database
          e2d = true;

          # "d2t" disables multimedia parsers (in case the uploads are malicious)
          d2t = true;

          # skips hashing file contents if path matches *.iso
          # nohash = "\.iso$";
        };
      };
    };
    # you may increase the open file limit for the process
    openFilesLimit = 8192;
  };
}
