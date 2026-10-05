# Forgejo's own git transport, served by an sshd inside this container.
#
# Why here and not on the host
# ----------------------------
# The obvious design is to keep port 22 on the host and have the host's sshd
# hand `git@` sessions into the container. That does not work, and the reason is
# not a configuration detail:
#
#   $ forgejo serv key-13 --config ...      # as the guest's git user
#   setting.go:203:mustCurrentRunUserMatch() [F]
#   Expect user 'forgejo' but current user is: 'git'
#
# `forgejo serv` refuses to run as anything except RUN_USER. The check lives in
# LoadSettings, so it fires for every subcommand, and there is no override --
# GITEA_I_AM_BEING_UNSAFE_RUNNING_AS_ROOT permits *root* and does not touch it.
# Verified both ways on the running instance:
#
#   as git     -> Expect user 'forgejo' but current user is 'git'
#   as forgejo -> advertises refs for SakulFlee/HomeLab (works)
#
# So the session must arrive as `forgejo`, which means the sshd that runs the
# forced command has to be able to log in as `forgejo` -- i.e. it lives in here.
# The host's sshd cannot do that, because it would have to authenticate against
# the guest's accounts.
#
# The consequence, stated plainly because it is the cost of this design: a push
# runs as `forgejo`, the identity that owns app.ini and can read SECRET_KEY,
# INTERNAL_TOKEN and the SMTP password. The alternative -- host sshd, serv as
# forgejo -- has the identical property, and the only thing it adds is a second
# place for the forced command to live. Running sshd here at least keeps the
# whole path inside the container, so the key list, the forced command and serv
# are all reading one database on one filesystem.
#
# What this does NOT do
# ---------------------
# It does not re-expose the secrets to a transport identity. There is no `git`
# login here at all: sshd runs as root, authenticates the key against the
# database, and the forced command is `forgejo serv`, which does its own
# authorisation. Nothing runs as the guest's `git` account, so nothing gains
# anything from that account's deliberately restricted view of the filesystem.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.forgejo;

  forgejo = "${pkgs.forgejo}/bin/forgejo";

  # Where Forgejo keeps app.ini. Passed explicitly because `forgejo serv` run
  # outside forgejo.service derives its config from the binary's own directory,
  # and under Nix that is a /nix/store path with no conf/app.ini beside it:
  #
  #   InitCfgProvider() [F] Unable to init config provider
  appIni = "${cfg.customDir}/conf/app.ini";

  # The key list, straight from Forgejo's own database.
  #
  # In here, not on the host, this is much simpler than the alternative: there is
  # no incus exec, no cross-container command, and no --project/--user pair to
  # get wrong. It is a local psql over a unix socket, authenticated by peer
  # credentials as the forgejo user.
  #
  # Read line by line, never `for entry in $keys`. Word splitting would make each
  # "entry" one whitespace-separated token, so the id would arrive alone and the
  # key would arrive as the *next* iteration.
  #
  # PATH is set explicitly and absolutely, and psql comes from the *guest's own*
  # postgresql, not from pkgs.postgresql.
  #
  # Two separate traps, both of which produce an empty key list and therefore a
  # silent "Permission denied" on every push rather than an error anyone reads:
  #
  # 1. The guest's inherited PATH carries no coreutils, so a bare cat or psql in
  #    this script dies with
  #       keys.sh: line 2: cat: command not found
  #    Same trap apply.sh documents for the guest's inherited PATH.
  #
  # 2. pkgs.postgresql is the *default* major version -- 17.11 in this nixpkgs --
  #    while the guest runs PostgreSQL 18 (postgresql_18, deliberately, because
  #    the dump was made by pg_dump 18 and pg_restore 17 refuses it). Reaching an
  #    18 database with a 17 client is exactly the mismatch that made the restore
  #    fail the first time. The generated script must therefore be built from the
  #    same postgresql_18 the service uses.
  keySource = pkgs.writeShellScript "forgejo-ssh-keys" ''
    set -euo pipefail

    export PATH=${lib.makeBinPath [
      pkgs.coreutils
      pkgs.util-linux
      config.services.postgresql.package
    ]}:/run/current-system/sw/bin

    # No keys registered is a valid answer and means nobody can log in. An *error*
    # must be distinguishable from that, or a stopped postgres would lock
    # everyone out with nothing saying why. stderr is deliberately not redirected:
    # sshd captures it into its own log, while stdout stays empty.
    # -U forgejo, NOT left to default. AuthorizedKeysCommandUser is root, and a bare
    # `psql -d forgejo` connects as the OS user -- which is root -- so peer
    # authentication rejects it:
    #
    #   FATAL: role "root" does not exist
    #
    # That produces an empty key list, which sshd reads as "no keys registered",
    # which surfaces as a bare "Permission denied (publickey)" on every push with
    # nothing in any log. Found by running the generated script as root inside the
    # guest, which is what sshd actually does; running it by hand as forgejo
    # worked fine and hid the bug completely.
    # This runs as root (AuthorizedKeysCommandUser), and peer authentication matches
    # the *OS* user against the database role -- so the query has to run as the
    # forgejo user, not merely name it. Both halves are required, and each on its
    # own fails with a different message:
    #
    #   psql -d forgejo          as root -> FATAL: role "root" does not exist
    #   psql -U forgejo -d ...   as root -> FATAL: Peer authentication failed
    #                             for user "forgejo"
    #
    # Either way the key list comes back empty, sshd reads that as "no keys
    # registered", and every push fails as a bare "Permission denied (publickey)"
    # with nothing logged anywhere.
    #
    # Found by running the generated script as root inside the guest, which is
    # what sshd does. Running it by hand as forgejo works perfectly and hides
    # both failures completely -- the single most misleading test result of this
    # whole exercise.
    #
    # runuser, not su: su needs a login shell and a controlling terminal, and
    # `su -c` from a non-tty context is a reliable source of hangs.
    keys=$(
      runuser -u ${cfg.user} -- \
        psql -d forgejo -tA -F" " \
          -c "SELECT id, content FROM public_key ORDER BY id" || true
    )

    while read -r id rest; do
      [ -n "''${id:-}" ] || continue

      # A registered key is "<type> <base64> <comment>". Anything else is skipped
      # rather than emitted: one malformed line in authorized_keys output is a
      # parse error that can cost the whole list.
      case "''${rest:-}" in
        ssh-*|ecdsa-*|sk-*) : ;;
        *) continue ;;
      esac

      # A non-numeric id would end up inside a shell word of the forced command.
      case "$id" in
        *[!0-9]*) continue ;;
      esac

      # `serv key-<id>`, and the key- prefix is part of the argument, not decoration.
      # Forgejo parses this itself and rejects anything else:
      #
      #   $ forgejo serv 13 --config ...
      #   Forgejo: Key ID format error
      #
      # Verified by running the generated script's own output back through a
      # shell the way sshd does. The form matches what Forgejo itself writes into
      # a managed authorized_keys file.
      printf 'command="%s serv key-%s --config %s",no-pty %s\n' \
        ${forgejo} "$id" ${appIni} "$rest"
    done <<<"$keys"
  '';

  # Where sshd looks, and where the install unit puts the script. Under /run and
  # a real file: see the AuthorizedKeysCommand note for why both halves matter and
  # why /etc does not work despite looking correct.
  keyDir = "/run/forgejo-ssh-keys";
  keyPath = "${keyDir}/keys";
in {
  # Copies the script out of the store on every boot.
  #
  # Wanted by sshd.service rather than multi-user.target so the ordering does not
  # depend on anything else happening to pull it in: if sshd starts before this
  # runs, AuthorizedKeysCommand names a file that does not exist, every key lookup
  # fails, and the symptom is the same bare `Permission denied (publickey)` as the
  # two earlier causes -- so it has to be impossible rather than unlikely.
  systemd.services.forgejo-ssh-keys-install = {
    description = "Install Forgejo's AuthorizedKeysCommand script outside the Nix store";
    wantedBy = [ "sshd.service" ];
    before = [ "sshd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Creates /run/forgejo-ssh-keys as 0755 root:root. RuntimeDirectory rather
      # than mkdir in ExecStart so systemd removes it on stop and recreates it on
      # every boot -- /run is tmpfs, and a stale copy from a previous boot with a
      # different store path would be worse than none.
      RuntimeDirectory = "forgejo-ssh-keys";
      RuntimeDirectoryMode = "0755";
      ExecStart = lib.getExe' pkgs.coreutils "install" +
        " -m 0555 -o root -g root ${keySource} ${keyPath}";
    };
  };

  # Restart sshd if the script's content ever changes shape, so a change to
  # keySource is not silently shadowed by a stale copy in /run. NixOS restarts the
  # unit on a changed ExecStart, and sshd is Restart=always on failure, so a
  # restart here is the cheap correct thing.
  systemd.services.sshd.restartTriggers = [ "forgejo-ssh-keys-install.service" ];

  # sshd exists only for git transport. It has no password login, no root
  # login, no forwarding and no terminal; it is reachable only on the network
  # forward the host sets up, and the only thing that can log in is a key that
  # is registered in the database.
  services.openssh = {
    enable = true;
    openFirewall = false; # the guest firewall is off; the host gates this
    settings = {
      # No host key in the image: Incus hands the instance one, and a baked-in key
      # would be identical in every copy of this image.
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      # git speaks the SSH protocol and nothing else.
      X11Forwarding = false;
      PrintMotd = false;
      LogLevel = "INFO";
    };
    extraConfig = lib.concatStringsSep "\n" [
      ""
      "# Git transport into Forgejo, in here rather than on the host."
      "# See ./ssh.nix for why `forgejo serv` cannot be reached"
      "# from the host's sshd at all."
      ""
      "# sshd runs as root, so AuthorizedKeysCommand can read the database as any"
      "# user. `forgejo` is right: peer authentication over the local unix socket"
      "# needs no password and grants nothing that root does not already have."
      #
      # /run/forgejo-ssh-keys/keys -- a REAL file, installed by
      # forgejo-ssh-keys-install below. Not the store path, and not anything under
      # /etc. OpenSSH refuses an AuthorizedKeysCommand whose RESOLVED path passes
      # through a group- or other-writable directory, and:
      #
      #   drwxrwxr-t root:nixbld /nix/store
      #
      # The group write is the whole problem, so the lookup fails before a single
      # key is offered:
      #
      #   error: Unsafe AuthorizedKeysCommand "...":
      #          bad ownership or modes for directory /nix/store
      #
      # and the symptom is a bare `Permission denied (publickey)` with nothing
      # else logged at LogLevel INFO.
      #
      # Two wrong fixes got here first, and both were caught on the host rather
      # than in testing:
      #
      #   1. The store path directly. /nix/store is 1775.
      #   2. /etc/ssh/forgejo-ssh-keys via environment.etc. That LOOKS safe --
      #      /etc, /etc/ssh are drwxr-xr-x root:root -- and the deployed guest
      #      showed exactly that chain. It still failed, because NixOS installs
      #      environment.etc entries as symlinks:
      #
      #        /etc/ssh/forgejo-ssh-keys -> /etc/static/ssh/forgejo-ssh-keys
      #                                    -> /nix/store/...-forgejo-ssh-keys
      #
      #      and auth_secure_path resolves the link before walking up, so it
      #      reaches /nix/store anyway. Reasoning that it walked the LEXICAL path
      #      is what made fix 2 look safe; it does not.
      #
      # So no NixOS-managed file can serve here, and the script is copied into
      # /run at boot instead. /run is tmpfs and drwxr-xr-x root:root, and the
      # directory is created 0755 root:root, which is the chain sshd accepts.
      "AuthorizedKeysCommand ${keyPath} %u"
      "AuthorizedKeysCommandUser root"
      ""
      "# Only the key list. This is what turns the old behaviour -- a password"
      "# prompt for a registered key -- into a working push."
      "AuthenticationMethods publickey"
      ""
      "# git plumbing: no terminal, and no way to turn the session into a tunnel"
      "# or an agent that outlives it."
      "PermitTTY no"
      "AllowTcpForwarding no"
      "AllowAgentForwarding no"
      "PermitTunnel no"
      "GatewayPorts no"
      ""
    ];
  };
}