{ config, pkgs, ... }: {
  sops.secrets."wireguard_server_private_key" = {};

  networking.wireguard.interfaces = {
    wg0 = {
      ips = [ "10.100.0.1/24" ];
      listenPort = 51820;
      privateKeyFile = config.sops.secrets.wireguard_server_private_key.path;

      peers = [
        {
          publicKey = "/nL6bknMr/9eytU0zdKE+hykHV1Lc0UzIhCIzb0OIgc=";
          allowedIPs = [ "10.100.0.2/32" ];
        }
        {
          publicKey = "ClMVYG1CLPUe4O8gWKbriZYe46vzHm5jV0vL8sCJsDI=";
          allowedIPs = [ "10.100.0.3/32" ];
        }
        {
          publicKey = "dMvt6494e1ZQahqxL3hC8DqrQm8KNKIcNeyvlM8MQjk=";
          allowedIPs = [ "10.100.0.4/32" ];
        }
        {
          publicKey = "1Q5bzB7lz60N+wZEpEXB28jeeZGhtroXhBCfHjlX7DY=";
          allowedIPs = [ "10.100.0.5/32" ];
        }
        {
          publicKey = "joSkTAmnwxJe0mkyKpVmLGC+HcFIYzd1BSzAZ+u+THA=";
          allowedIPs = [ "10.100.0.6/32" ];
        }
      ];
    };
  };

  systemd.services.ssh-proxy-forgejo = {
    description = "SSH proxy to Forgejo for VPN clients";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:2222,fork,reuseaddr,bind=10.100.0.1 TCP:127.0.0.1:22";
      Restart = "always";
      RestartKillSignal = "SIGTERM";
      TimeoutStopSec = 5;
      KillMode = "mixed";
    };
  };

  networking.nftables.enable = true;

  networking.nat.enable = true;
  networking.nat.externalInterface = "eno1";
  networking.nat.internalInterfaces = [ "wg0" ];

  networking.firewall = {
    allowedUDPPorts = [ 51820 ];
    trustedInterfaces = [ "wg0" "podman0" "podman1" ];
    filterForward = true;
    extraForwardRules = ''
      iifname "wg0" accept
      iifname "podman*" accept
    '';
  };

  boot.kernel.sysctl."net.ipv4.ip_forward" = true;
}
