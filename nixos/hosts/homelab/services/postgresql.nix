{ config, pkgs, lib, ... }: {
  services.postgresql = {
    enable = true;
    ensureDatabases = [ "forgejo" "woodpecker" "bitmagnet" ];
    ensureUsers = [
      {
        name = "forgejo";
        ensureDBOwnership = true;
      }
      {
        name = "woodpecker";
        ensureDBOwnership = true;
      }
      {
        name = "bitmagnet";
        ensureDBOwnership = true;
      }
    ];
    authentication = ''
      local forgejo forgejo peer map=forgejo-map
      local woodpecker woodpecker peer map=woodpecker-map
      host woodpecker woodpecker 127.0.0.1/32 trust
      host woodpecker woodpecker ::1/128 trust
      host bitmagnet bitmagnet 127.0.0.1/32 scram-sha-256
      host bitmagnet bitmagnet ::1/128 scram-sha-256
      host bitmagnet bitmagnet 10.88.0.0/16 scram-sha-256
    '';
    identMap = ''
      forgejo-map /^(forgejo|git)$ forgejo
      woodpecker-map /^(woodpecker)$ woodpecker
    '';
    settings = {
      listen_addresses = lib.mkForce "localhost,10.88.0.1";
      logging_collector = true;
      log_directory = "log";
    };
  };

  systemd.services.postgresql = {
    postStart = lib.mkAfter ''
      psql -d bitmagnet -c "ALTER USER bitmagnet WITH PASSWORD 'bitmagnet';" 2>/dev/null || true
    '';
  };

  systemd.services.postgresql-dump = {
    description = "PostgreSQL database dump";
    after = [ "postgresql.service" ];
    path = with pkgs; [ postgresql ];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      StateDirectory = "postgresql-dumps";
    };
    script = ''
      mkdir -p /var/lib/postgresql-dumps
      DATE=$(date +%Y%m%d-%H%M%S)
      for DB in forgejo woodpecker bitmagnet paperless; do
        pg_dump -d "$DB" -Fc -f "/var/lib/postgresql-dumps/$DB-$DATE.dump"
      done
      # Keep only last 48 hours of dumps (48 hourly backups)
      find /var/lib/postgresql-dumps -name '*.dump' -type f -mmin +2880 -delete
    '';
  };

  systemd.timers.postgresql-dump = {
    description = "Hourly PostgreSQL dump";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };

  systemd.services.homelab-restic = {
    after = [ "postgresql-dump.service" ];
  };

  services.homelab-restic = {
    enable = true;
    paths = [ "/var/lib/postgresql-dumps" ];
  };
}
