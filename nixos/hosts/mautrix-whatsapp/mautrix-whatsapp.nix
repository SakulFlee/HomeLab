{ config, pkgs, lib, ... }: {
  # mautrix-whatsapp depends on olm which is marked insecure
  nixpkgs.config.permittedInsecurePackages = [ "olm-3.2.16" ];

  services.mautrix-whatsapp = {
    enable = true;
    settings = {
      appservice = {
        address = "http://10.0.0.125:29318";
      };
      homeserver = {
        address = "http://10.0.0.117:6167";
        domain  = "sakul-flee.de";
      };
      bridge = {
        permissions = {
          "@sakulflee:sakul-flee.de" = "admin";
          "*"                         = "relay";
        };
        encryption = {
          allow       = true;
          default     = true;
          allow_key_sharing = true;
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 29318 ];

  # LXC containers don't support systemd namespace sandboxing
  systemd.services.mautrix-whatsapp.serviceConfig = {
    PrivateTmp       = lib.mkForce false;
    PrivateNetwork   = lib.mkForce false;
    PrivateDevices   = lib.mkForce false;
    ProtectSystem    = lib.mkForce "no";
    ProtectHome      = lib.mkForce false;
    NoNewPrivileges  = lib.mkForce false;
  };
}
