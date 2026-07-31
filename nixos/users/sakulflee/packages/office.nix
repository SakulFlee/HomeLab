{ pkgs, ... }: {
  home.packages = with pkgs; [
    onlyoffice-desktopeditors
    libreoffice-qt-fresh

    # OCR
    tesseract
  ];
}

