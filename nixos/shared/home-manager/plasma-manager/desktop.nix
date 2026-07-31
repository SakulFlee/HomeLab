{ ... }: {
  programs.plasma.desktop = {
    widgets = [];

    icons = {
      arrangement = "topToBottom";
      alignment = "right";
      sorting.mode = "date";
    };
  };
}
