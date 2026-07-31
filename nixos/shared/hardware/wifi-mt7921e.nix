{ ... }: {
  # WiFi Card (prevents speed and reliability issues)
  boot.extraModprobeConfig = ''
    options mt7921e disable_aspm=1
  '';
}
