{ config, pkgs, lib, fansly-recorder, ... }:
{
  imports = [
    ../../modules
    ./service.nix
  ];

  networking.hostName = "fansly-recorder";

  environment.systemPackages = [
    fansly-recorder.packages.x86_64-linux.default
  ];

  systemd.tmpfiles.settings."fansly-recorder" = {
    "/var/lib/fansly-recorder"."d" = {
      mode = "0755";
      user = "root";
      group = "root";
    };
  };
}
