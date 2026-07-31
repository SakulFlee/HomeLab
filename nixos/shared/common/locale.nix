{ pkgs, ... }: {
  # Timezone
  time.timeZone = "Europe/Berlin";

  # Language & Locale
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "de";
  services.xserver.xkb = {
    layout = "de";
    variant = "";
  };
}
