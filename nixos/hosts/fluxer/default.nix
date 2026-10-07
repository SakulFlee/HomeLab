# NixOS inside the "fluxer" VM.
{ config, lib, pkgs, ... }:
let
  fluxerDir = "/opt/fluxer";
in
{
  imports = [
    ./disk.nix
    ./compose.nix
  ];

  networking.hostName = "fluxer";

  # VM gets its network configured via Incus; use networkd for consistency
  networking.useNetworkd = true;

  systemd.network.networks."10-incus" = {
    matchConfig.Name = "eth0";
    networkConfig = {
      Address = [ "10.0.0.103/24" ];
      Gateway = "10.0.0.1";
      DNS = [ "10.0.0.1" "1.1.1.1" "9.9.9.9" ];
    };
  };

  # Vendor upstream Fluxer files into the VM image.
  environment.etc = {
    "fluxer/docker-compose.yml" = {
      source = ./vendor/docker-compose.yml;
      target = "fluxer/docker-compose.yml";
    };
    "fluxer/docker-compose.proxy.yml" = {
      source = ./vendor/docker-compose.proxy.yml;
      target = "fluxer/docker-compose.proxy.yml";
    };
    "fluxer/Caddyfile" = {
      source = ./vendor/Caddyfile;
      target = "fluxer/Caddyfile";
    };
    "fluxer/livekit.yaml" = {
      source = ./vendor/livekit.yaml;
      target = "fluxer/livekit.yaml";
    };
    "fluxer/.env.example" = {
      source = ./vendor/.env.example;
      target = "fluxer/.env.example";
    };
  };

  # Copy to /opt/fluxer on first boot or during activation.
  systemd.services.fluxer-vendor = {
    description = "Copy Fluxer stack files to ${fluxerDir}";
    after = [ "network-online.target" ];
    before = [ "fluxer-compose.service" "fluxer-env.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      set -e
      mkdir -p ${fluxerDir}
      cp -f /etc/fluxer/docker-compose.yml ${fluxerDir}/ 2>/dev/null || true
      cp -f /etc/fluxer/docker-compose.proxy.yml ${fluxerDir}/ 2>/dev/null || true
      cp -f /etc/fluxer/Caddyfile ${fluxerDir}/ 2>/dev/null || true
      cp -f /etc/fluxer/livekit.yaml ${fluxerDir}/ 2>/dev/null || true
      cp -f /etc/fluxer/.env.example ${fluxerDir}/ 2>/dev/null || true
      chmod 0644 ${fluxerDir}/* 2>/dev/null || true
    '';
  };

  # Open common ports (internal only; public routing via Caddy)
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 8080 ]; # Edge HTTP when using proxy overlay
    allowedUDPPorts = [ 7882 ]; # LiveKit
  };

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
    };
  };

  users.users.root.initialHashedPassword = lib.mkForce "!";

  system.stateVersion = "25.11";
}