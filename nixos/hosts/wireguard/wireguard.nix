{ config, ... }: {
  sops.secrets."wireguard_server_private_key" = {
    sopsFile = ../../secrets/wireguard.sops.yaml;
  };

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
      ];
    };
  };

  networking.nat.enable = true;
  networking.nat.externalInterface = "eth0";
  networking.nat.internalInterfaces = [ "wg0" ];

  networking.firewall = {
    allowedUDPPorts = [ 51820 ];
    trustedInterfaces = [ "wg0" ];
    extraCommands = ''
      iptables -A nixos-fw-forward -i wg0 -j ACCEPT
      iptables -A nixos-fw-forward -o wg0 -m state --state ESTABLISHED,RELATED -j ACCEPT
    '';
    extraStopCommands = ''
      iptables -D nixos-fw-forward -i wg0 -j ACCEPT
      iptables -D nixos-fw-forward -o wg0 -m state --state ESTABLISHED,RELATED -j ACCEPT
    '';
  };

  boot.kernel.sysctl."net.ipv4.ip_forward" = true;
}
