{ ... }: {
  # ZRAM compressed swap in RAM (priority 100 by default).
  # High priority means it's used first — fast and reduces disk writes.
  # Falls back to real swap partitions for hibernation or overflow.
  zramSwap.enable = true;
}
