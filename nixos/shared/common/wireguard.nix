{ pkgs, config, lib, ... }:
let
  serverPublicKey = "tDj18GzgpKzFsfu0JdltiienO5uvJDw1e4Hwq1551DI=";
  hostCfg = {
    "Evil-Donkey" = {
      address = [ "10.100.0.2/32" ];
    };
    "Cindry" = {
      address = [ "10.100.0.3/32" ];
    };
    "SteamDeck" = {
      address = [ "10.100.0.5/32" ];
    };
  };
  this = hostCfg.${config.networking.hostName} or (throw "wireguard.nix: unknown host ${config.networking.hostName}");
in {
  sops.defaultSopsFile = ../../secrets.yaml;
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.secrets.${"wireguard_${config.networking.hostName}_private_key"} = { };

  networking.wg-quick.interfaces.wg0 = {
    address = this.address;
    privateKeyFile = config.sops.secrets.${"wireguard_${config.networking.hostName}_private_key"}.path;
    dns = [ "10.100.0.1" ];
    peers = [{
      publicKey = serverPublicKey;
      endpoint = "vpn.sakul-flee.de:51820";
      allowedIPs = [ "0.0.0.0/0" "::/0" ];
      persistentKeepalive = 25;
    }];
    postUp = ''
      if ping -c 1 -W 1 192.168.178.200 &>/dev/null; then
        ${pkgs.wireguard-tools}/bin/wg set wg0 peer ${serverPublicKey} endpoint 192.168.178.200:51820
      fi
    '';
  };
}
