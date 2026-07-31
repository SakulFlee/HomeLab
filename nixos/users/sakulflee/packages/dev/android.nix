{ pkgs, ... }: {
  home.packages = with pkgs; [
    # platform tools (adb)
    android-tools
    # MTP
    android-file-transfer
  ];

  # Required to accept licenses
  nixpkgs.config.android_sdk.accept_license = true;
}