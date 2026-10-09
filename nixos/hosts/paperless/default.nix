# NixOS system for the Incus instance "paperless".
#
# Paperless-ngx with its own PostgreSQL 18, redis and tika/gotenberg, on the
# `default` Incus project -- which is what lets the Syncthing hub mount this
# instance's media volume read-only (see nixos/replicated-volumes.nix).
#
# The package constraint that shapes this file: the restored database comes from
# the k3s deployment, which ran ghcr.io/paperless-ngx/paperless-ngx:3.3.0, and
# Paperless schema migrations only ever run forwards. The pinned nixos-26.05
# nixpkgs ships 2.20.15 -- an unsafe downgrade against a 3.3.0 schema, exactly
# the trap the Forgejo migration documents about its own version -- so the
# paperless package is taken from a pinned nixos-unstable rev
# (inputs.nixpkgs-paperless) that ships exactly 3.3.0. Everything else stays on
# 26.05. See nixos/flake.nix for the pin and its rationale.
{ lib, pkgs, inputs, ... }:
let
  paperlessPackage =
    inputs.nixpkgs-paperless.legacyPackages.x86_64-linux.paperless-ngx;
in
{
  networking.hostName = "paperless";

  # Same firewall posture as every other instance: the host and Incus gate
  # inbound traffic -- Caddy's VPN gate on the vhost, and there is no LAN
  # forward at all -- and a second firewall in the guest would only re-filter
  # what the host already let through.
  networking.firewall.enable = false;

  # Router DNS, same as the other instances (not the host's 192.168.178.200).
  networking.nameservers = [ "192.168.178.1" ];

  # Not exposed: Incus reaches the instance via exec, and nothing forwards 22.
  services.openssh.enable = false;

  # curl, for reaching the app and, at verification time, the sync hub.
  environment.systemPackages = [ pkgs.curl ];

  # ---------------------------------------------------------------------------
  # PostgreSQL 18, exactly the Forgejo pattern (../forgejo/default.nix)
  # ---------------------------------------------------------------------------
  services.postgresql = {
    enable = true;

    # 18, not the module default. The dump being restored was written by
    # pg_dump from postgres:16 (the CNPG instance the k3s deployment runs).
    # pg_restore refuses an archive written by a pg_dump NEWER than its own
    # server, so a 16 or 17 server here could not restore this archive; 18
    # forward-reads it.
    package = pkgs.postgresql_18;

    # The `paperless-postgres` volume is mounted here. The module default is
    # /var/lib/postgresql/<major>, and a volume mounted where the server never
    # looks is the same silence forgejo documented -- see that file's comment.
    dataDir = "/var/lib/postgresql/data";

    # Stated rather than inherited, same reason as forgejo.
    settings.unix_socket_directories = "/run/postgresql";

    # services.paperless runs with createLocally = false, so the paperless
    # module does NOT declare database or role -- declare them here instead.
    # The default pg_hba line `local all all peer` is what makes a socket
    # connection as the `paperless` OS user passwordless, no extra auth config.
    ensureDatabases = [ "paperless" ];
    ensureUsers = [
      {
        name = "paperless";
        ensureDBOwnership = true;
      }
    ];
  };

  # Because dataDir is not the module default, StateDirectory does not apply and
  # nothing would create or chown the mount point. Incus creates it 0711
  # root:root, and initdb refuses to run in a directory it does not own. This is
  # exactly forgejo's unit, renamed. `install -d` is idempotent and keeps
  # whatever is already inside.
  systemd.services.paperless-postgres-dir = {
    description = "Create and own PGDATA, which the module does not do for a non-default dataDir";
    wantedBy = [ "multi-user.target" ];
    before = [ "postgresql.service" ];
    after = [ "local-fs.target" ];
    path = [ pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe' pkgs.coreutils "install" + " -d -m 0700 -o postgres -g postgres /var/lib/postgresql/data";
    };
  };

  # ---------------------------------------------------------------------------
  # Paperless-ngx
  # ---------------------------------------------------------------------------
  services.paperless = {
    # Deliberately OFF in this commit. Migration, not a fresh install: the
    # database is going to arrive as a pg_dump, and if paperless booted before
    # the restore it would run its migrations against an empty database, create
    # the schema the dump is about to overwrite, and generate a secret key that
    # would then be discarded. The instance is created stopped (see incus.nix);
    # the loader streams the volumes while it is stopped, the dump is restored
    # onto the fresh PostgreSQL, and only then does the final migration commit
    # flip this to true (and autostart in incus.nix). On that first real boot
    # the scheduler's pre-start `migrate` finds the restored schema already
    # current and no-ops.
    enable = false;

    # 3.3.0, the exact version k3s ran -- see the header comment. The
    # tesseract-language override the module applies to this package still
    # works: the 3.3.0 derivation takes tesseract5 as a function argument like
    # every nixpkgs paperless-ngx does.
    package = paperlessPackage;

    # Caddy dials in over incusbr0, so the listener must be on the instance's
    # address, not just loopback.
    address = "0.0.0.0";

    # Tika and gotenberg, enabled by setting the PAPERLESS_TIKA/GOTENBERG env
    # vars the module owns. Not to be confused with `enable`: coupled to the
    # scheduler service, so it stays inert while enable = false.
    configureTika = true;

    # The database lives in the PostgreSQL above, not a fresh db the module
    # would create. With createLocally = false the module deliberately does NOT
    # set PAPERLESS_DB* -- that is this block's job. Also, the module's
    # createLocally branch is what runs its own PostgreSQL package selection.
    database.createLocally = false;

    domain = "paperless.sakul-flee.de";

    settings = {
      # The DB role and database are declared in services.postgresql above;
      # these point the app at them. A socket host with no port -> local Unix
      # socket, and the default peer auth makes the `paperless` OS user map to
      # the `paperless` role.
      PAPERLESS_DBENGINE = "postgresql";
      PAPERLESS_DBHOST = "/run/postgresql";
      PAPERLESS_DBNAME = "paperless";
      PAPERLESS_DBUSER = "paperless";

      # Chart parity, from apps/paperless/helm-release.yaml (k3s values).
      # PAPERLESS_URL comes from `domain` above; the rest the chart set are
      # mirrored here.
      PAPERLESS_CSRF_TRUSTED_ORIGINS = "https://paperless.sakul-flee.de";
      PAPERLESS_TIME_ZONE = "Europe/Berlin";
      PAPERLESS_OCR_LANGUAGE = "deu+eng";
      # The helm chart's value was the JSON serialisation of exactly this.
      PAPERLESS_OCR_USER_ARGS = {
        optimize = 1;
        pdfa_image_compression = "lossless";
      };
      PAPERLESS_CONSUMER_IGNORE_PATTERNS = [ ".DS_STORE/*" "desktop.ini" ];
      PAPERLESS_TASK_WORKERS = "2";
    };
  };

  # ---------------------------------------------------------------------------
  # The replicated-volume marker, and the uid/gid pin it depends on
  # ---------------------------------------------------------------------------
  #
  # The Syncthing hub mounts the media volume READ-ONLY, so it can never write
  # the `.stfolder` marker a Syncthing folder needs before it will scan -- the
  # producer has to. The loader writes it during the data move, and this rule
  # replants it if it ever goes missing (say, when the media volume is replaced
  # or the marker is cleaned up with the loader's scratch container). Numeric
  # ids: services.paperless is disabled in this commit, so the `paperless` user
  # does not exist yet -- but ids.uids.paperless is pinned to 987 below, which
  # both this rule and the module's own user (once enabled) agree on.
  systemd.tmpfiles.rules = [
    "d /var/lib/paperless/media/.stfolder 0755 987 987 -"
  ];

  # The module auto-allocates the paperless uid/gid; pinning them is load-bearing
  # for a migration whose files arrive owned by a hardcoded number. The loader
  # chowns every extracted file to 987:987; if the module were free to allocate
  # a different uid/gid on the final commit's first boot, every one of those
  # files would suddenly be owned by nobody. The known owners are the only thing
  # that is stable across the migration.
  ids.uids.paperless = 987;
  ids.gids.paperless = 987;
}