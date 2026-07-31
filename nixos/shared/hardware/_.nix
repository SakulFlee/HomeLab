{ ... }: {
  # Does NOT and should NOT contain everything!
  # Some of the files in here are EXCLUSIVE.
  # E.g. GPU config needs to be manually imported.
  # Default setup only covers sane defaults for networking, bluetooth, audio, etc.

  imports = [
    ./audio.nix
    ./bluetooth.nix
    ./networking.nix
    ./i2c.nix
    ./microcode.nix
    ./firmware.nix
  ];
}