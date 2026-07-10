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

  # LXC containers can't do systemd namespace sandboxing — disable all of it
  systemd.services.mautrix-whatsapp.serviceConfig = {
    PrivateUsers          = lib.mkForce false;
    PrivateTmp            = lib.mkForce false;
    PrivateNetwork        = lib.mkForce false;
    PrivateDevices        = lib.mkForce false;
    ProtectHome           = lib.mkForce false;
    ProtectSystem         = lib.mkForce "no";
    ProtectClock          = lib.mkForce false;
    ProtectControlGroups  = lib.mkForce false;
    ProtectHostname       = lib.mkForce false;
    ProtectKernelLogs     = lib.mkForce false;
    ProtectKernelModules  = lib.mkForce false;
    ProtectKernelTunables = lib.mkForce false;
    LockPersonality       = lib.mkForce false;
    NoNewPrivileges       = lib.mkForce false;
    RestrictRealtime      = lib.mkForce false;
    RestrictSUIDSGID      = lib.mkForce false;
    SystemCallArchitectures = lib.mkForce null;
    SystemCallFilter      = lib.mkForce null;
    SystemCallErrorNumber = lib.mkForce null;
  };
}
