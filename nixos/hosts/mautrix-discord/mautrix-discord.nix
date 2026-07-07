{ config, pkgs, ... }:
let
  asToken = "1q6BzIIfaKDcaNE9qtjTORb07leCva3rRrVhNCO_qOOuhJ05CTBkkgCDk6CCC-dl";
  hsToken = "vUAZ0cyDUtvLSBrxSapJKt2rUXnINjZM8UhXjWv8kwRZvtJQrRhJpbsQPogj_P--";
in {
  nixpkgs.config.permittedInsecurePackages = [
    "olm-3.2.16"
  ];
  services.mautrix-discord = {
    enable = true;
    registerToSynapse = false;

    settings = {
      homeserver = {
        address = "http://10.0.0.117:6167";
        domain = "sakul-flee.de";
      };

      appservice = {
        address = "http://10.0.0.118:29334";
        hostname = "0.0.0.0";
        port = 29334;
        as_token = asToken;
        hs_token = hsToken;
      };

      bridge = {
        permissions = {
          "sakul-flee.de" = "user";
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 29334 ];
}
