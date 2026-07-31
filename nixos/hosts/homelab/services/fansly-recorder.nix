{ pkgs, inputs, ... }:
let
  pkg = inputs.fansly-recorder.packages.x86_64-linux.default;

  wrapper = pkgs.writeShellScript "fansly-recorder-wrapper" ''
    set -euo pipefail

    TRACKING_FILE="/mnt/nas/NSFW/streams/.tracking"
    AUTH_FILE="/var/lib/fansly-recorder/auth.json"
    OUTPUT_DIR="/mnt/nas/NSFW/streams"
    PID_FILE="/var/lib/fansly-recorder/pids"
    CHECK_INTERVAL=60
    WATCH_INTERVAL=300

    mkdir -p "$OUTPUT_DIR"
    touch "$PID_FILE"

    log() { echo "[fansly-recorder] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }

    cleanup() {
      log "Shutting down all recorders..."
      while read -r line; do
        kill "''${line#* }" 2>/dev/null || true
      done < "$PID_FILE"
      rm -f "$PID_FILE"
      exit 0
    }
    trap cleanup SIGTERM SIGINT

    while true; do
      if [ -f "$TRACKING_FILE" ]; then
        while IFS= read -r url; do
          [[ -z "$url" || "$url" =~ ^# ]] && continue

          pid=""
          if [ -f "$PID_FILE" ]; then
            pid=$(grep -F "$url" "$PID_FILE" | tail -1 | sed 's/.* //' || true)
          fi

          if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            continue
          fi

          [ -n "$pid" ] && sed -i '\|^'"$url"' |d' "$PID_FILE" || true

          log "Starting recorder for $url"
          (cd "$OUTPUT_DIR" && ${pkg}/bin/fansly-recorder \
            --url "$url" \
            --storage-state "$AUTH_FILE" \
            --watch --interval "$WATCH_INTERVAL" \
            --format mkv) &
          echo "$url $!" >> "$PID_FILE"
        done < "$TRACKING_FILE"
      fi

      if [ -f "$PID_FILE" ]; then
        temp=$(mktemp)
        while read -r line; do
          pid="''${line#* }"
          if kill -0 "$pid" 2>/dev/null; then
            echo "$line" >> "$temp"
          else
            wait "$pid" 2>/dev/null || true
            url="''${line%% *}"
            log "Recorder for $url exited"
          fi
        done < "$PID_FILE"
        mv "$temp" "$PID_FILE"
      fi

      sleep "$CHECK_INTERVAL"
    done
  '';
in {
  environment.systemPackages = [
    inputs.fansly-recorder.packages.x86_64-linux.default
  ];

  systemd.tmpfiles.settings."fansly-recorder" = {
    "/var/lib/fansly-recorder"."d" = {
      mode = "0755";
      user = "root";
      group = "root";
    };
  };

  systemd.services.fansly-recorder = {
    description = "Fansly stream recorder";
    after = [ "network.target" "remote-fs.target" ];
    wants = [ "remote-fs.target" ];
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [ gnused ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${wrapper}";
      Restart = "always";
      RestartSec = 10;
    };
  };
}
