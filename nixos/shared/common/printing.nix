{ pkgs, ...}:
{
  services.printing = {
    enable = true;
    drivers = with pkgs; [ 
      # CANON printer drivers
      cnijfilter2

      # For file conversion
      ghostscript

      # Standard open-source drivers
      gutenprint

      # Fallback
      cups-filters
    ];

    browsed.enable = false;
  };

  environment.systemPackages = with pkgs; [
      # Scanning
      kdePackages.skanpage
  ];

  hardware.printers = {
    ensurePrinters = [
      {
        name = "Canon_TR4500_series";
        location = "Home";

        deviceUri = "dnssd://Canon%20TR4500%20series%20(AIR)._ipp._tcp.local/";
        model = "canontr4500.ppd";

        ppdOptions = {
          media = "a4";
          sides = "two-sided-long-edge";
        };
      }
    ];
    ensureDefaultPrinter = "Canon_TR4500_series";
  };
}
