{ ... }: {
  # The host's own administrative SSH, moved to 2222 so that port 22 can be
  # DNAT'd to the Forgejo instance for git.
  #
  # Why the move rather than the alternative: pushes want
  # ssh://forgejo@forgejo.sakul-flee.de/SakulFlee/HomeLab.git, and the DNAT that
  # carries port 22 to that instance is per-port and unconditional. There is no
  # way to say "22 goes to Forgejo except for connections coming from the
  # administrator" -- Incus implements a forward as an nftables DNAT rule, and
  # DNAT has no notion of which account is being logged into.
  #
  # So one of the two has to give up 22. Git transport is the one that cannot
  # move: the instance advertises SSH_PORT=22, and changing that would put a
  # non-standard port into every clone URL on every machine and every CI runner.
  # The host's own SSH has exactly one client -- whoever administers this box --
  # and 2222 is a one-line change in one ~/.ssh/config.
  #
  # Verified rather than assumed, and the first attempt at this was wrong.
  #
  # `ports`, NOT settings.Port. nixpkgs *generates* the Port lines from `ports`:
  #
  #   lib.map (port: "Port ${toString port}") cfg.ports
  #
  # so setting settings.Port as well produces two directives, and the built host
  # config had both:
  #
  #   10:Port 2222
  #   17:Port 22
  #
  # sshd binds the first and the second is a trap for whoever reads the file
  # next -- and worse, 22 staying bound is exactly the collision this change
  # exists to avoid, since port 22 is about to be DNAT'd to Forgejo.
  #
  # `ports` is the single source of truth: it drives the generated Port line, the
  # listen addresses, and networking.firewall.allowedTCPPorts together, so the
  # three cannot drift.
  #
  # Incus does not care which port a forward claims, so nothing here conflicts
  # with the existing 80/443 forward on the same listen address.
  services.openssh = {
    enable = true;
    openFirewall = true;
    ports = [ 2222 ];
    settings.X11Forwarding = true;
  };
}