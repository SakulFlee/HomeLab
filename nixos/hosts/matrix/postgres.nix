{ config, pkgs, lib, ... }: {
  sops.secrets."database_password" = { owner = "matrix-synapse"; };

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16;

    initialScript = pkgs.writeText "matrix-synapse-init.sql" ''
      CREATE ROLE matrix-synapse WITH LOGIN PASSWORD null;
      CREATE DATABASE matrix-synapse OWNER matrix-synapse;
      GRANT ALL PRIVILEGES ON DATABASE matrix-synapse TO matrix-synapse;
    '';

    settings = {
      shared_buffers = "1GB";
      effective_cache_size = "3GB";
      work_mem = "32MB";
      maintenance_work_mem = "256MB";
      max_parallel_workers_per_gather = 2;
      max_parallel_workers = 4;
      max_worker_processes = 8;

      wal_buffers = "64MB";
      min_wal_size = "1GB";
      max_wal_size = "4GB";
      checkpoint_completion_target = 0.9;

      random_page_cost = 1.1;
      effective_io_concurrency = 200;

      huge_pages = "try";

      max_connections = 100;

      log_timezone = "UTC";
      timezone = "UTC";

      unix_socket_directories = "/run/postgresql";
    };
  };

  systemd.services.postgresql.serviceConfig = {
    MemoryMax = "2G";
    MemoryHigh = "1.5G";
  };

  systemd.services.postgresql-vacuum = {
    description = "PostgreSQL weekly vacuum analyze";
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      ExecStart = "${config.services.postgresql.package}/bin/psql -U matrix-synapse matrix-synapse -c 'VACUUM ANALYZE'";
    };
  };

  systemd.timers.postgresql-vacuum = {
    description = "Weekly PostgreSQL vacuum";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
    };
  };
}
