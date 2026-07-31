{ config, pkgs, lib, ... }: {
  services.paperless = {
    enable = true;
    # Bind to localhost; Caddy reverse proxies from the domain
    address = "127.0.0.1";
    port = 28981;

    # Domain for CSRF validation and URL generation
    domain = "paperless.sakul-flee.de";

    # Use PostgreSQL (already running on HomeLab)
    database.createLocally = true;

    # Enable Tika + Gotenberg for Office docs and email files
    configureTika = true;

    # OCR German and English documents
    settings = {
      PAPERLESS_OCR_LANGUAGE = "deu+eng";
      PAPERLESS_OCR_USER_ARGS = {
        optimize = 1;
        pdfa_image_compression = "lossless";
      };
      # CSRF validation behind Caddy reverse proxy
      PAPERLESS_URL = "https://paperless.sakul-flee.de";
      # Gotenberg is on port 3001 (port 3000 is used by Woodpecker)
      PAPERLESS_TIKA_GOTENBERG_ENDPOINT = "http://localhost:3001";
      # Ignore macOS metadata files in consumption
      PAPERLESS_CONSUMER_IGNORE_PATTERN = [
        ".DS_STORE/*"
        "desktop.ini"
      ];
    };

    # Auto-export documents nightly for backup purposes
    exporter.enable = true;
  };

  # Gotenberg — port 3001 because Woodpecker uses 3000
  services.gotenberg = {
    port = 3001;
    libreoffice.autoStart = true;
  };

  # Backup paperless data directory to NAS via restic
  services.homelab-restic = {
    enable = true;
    paths = [ "/var/lib/paperless" ];
  };
}
