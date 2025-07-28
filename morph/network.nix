let
  pkgs = import (import ./nixpkgs.nix) { };
in
{
  network = {
    inherit pkgs;
    description = "HomeLab";
  };

  # Define each host
  "cf-ddns" =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      # deployment = {
      #   targetHost = "192.168.100.1";
      #   targetPort = 22;
      #   targetUser = "root";
      # };

      imports = [ ./hosts/cf-ddns/configuration.nix ];
    };
}
