{ ... }: {
  # Allows your file manager to mount local drives/SD cards without root permissions
  services.udisks2.enable = true;

  # GVFS, which handles trash, network shares, and extra mounting features
  services.gvfs.enable = true;
}