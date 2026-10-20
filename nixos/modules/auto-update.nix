{ config, pkgs, ... }:

let
  nixosRebuildBin = "${pkgs.nixos-rebuild}/bin/nixos-rebuild";
  gitBin = "${pkgs.git}/bin/git";
in {
  security.sudo.extraRules = [
    {
      users = [ "sakulflee" ];
      commands = [
        {
          command = nixosRebuildBin;
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  systemd.services.nixos-auto-update = {
    description = "Auto-update NixOS and Incus configuration from Git";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [
      bash
      coreutils
      git
      jq
      libnotify
      nix
      nixos-rebuild
      opentofu
      openssh
      sudo
      systemd
      util-linux
    ];

    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/etc/nixos";
      # Image builds, Tofu plans and instance replacements can take well past
      # the default timeout.
      TimeoutStartSec = "2h";
    };

    script = ''
      cd /etc/nixos

      notify_all() {
        local title="$1" body="$2" urgency="$3"
        for bus in /run/user/*/bus; do
          [ -S "$bus" ] || continue
          uid="''${bus#/run/user/}"; uid="''${uid%%/*}"
          user=$(id -nu "$uid" 2>/dev/null) || continue
          sudo -u "$user" \
            DISPLAY=":0" DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
            notify-send --app-name="NixOS Auto Updater" --urgency="$urgency" \
              "$title" "$body" >/dev/null 2>&1 || true
        done
      }

      notify() {
        if command -v notify-send >/dev/null 2>&1; then
          notify_all "$1" "$2" "$3"
        fi
      }

      # Keep the host rebuild and the Tofu apply in one serialized operation.
      # This lock only coordinates this service; a manual apply still uses
      # Tofu's own state lock.
      LOCK_FILE=/run/lock/nixos-auto-update.lock
      exec 9>"$LOCK_FILE"
      if ! flock -n 9; then
        echo "Auto-update: another run is already active; skipping"
        exit 0
      fi

      ${gitBin} fetch origin main --quiet || echo "Auto-update: git fetch failed"
      BEHIND=$(${gitBin} rev-list --count HEAD..origin/main || echo 0)

      if [ "$BEHIND" -gt 0 ]; then
        echo "Auto-update: $BEHIND commits behind — updating..."

        notify "NixOS Auto Updater" "Updates detected, rebuilding..." normal

        if ! ${gitBin} merge --ff-only origin/main; then
          echo "Auto-update: merge failed (diverged?)"
          notify "NixOS Auto Updater" "Merge failed. Check journalctl -u nixos-auto-update" critical
          exit 1
        fi

        echo "--- nixos-rebuild start ---"
        EXIT_CODE=0
        # --flake is mandatory: /etc/nixos is the *repo root* and has no
        # flake.nix of its own (the flake is at ./nixos/flake.nix). Without it
        # nixos-rebuild falls back to the legacy '<nixpkgs/nixos>' channel path,
        # which ignores this repo's pinned inputs and forwards our extra flags
        # to nix-build -- where --print-build-logs is rejected as unrecognised.
        # The empty attribute after '#' resolves the output from the hostname
        # (HomeLab).
        ${nixosRebuildBin} switch --flake nixos/# --show-trace --print-build-logs || EXIT_CODE=$?
        # Exit code 4 means "switched successfully but some services failed" — treat as success
        [ "$EXIT_CODE" -eq 4 ] && EXIT_CODE=0
        echo "--- nixos-rebuild end (exit: $EXIT_CODE) ---"

        if [ "$EXIT_CODE" -ne 0 ]; then
          notify "NixOS Auto Updater" "Host rebuild failed. Check journalctl -u nixos-auto-update" critical
          exit 1
        fi

        notify "NixOS Auto Updater" "Host rebuilt; checking Incus images and Tofu..." normal

        if ! ./incus/gen-tf.sh; then
          notify "NixOS Auto Updater" "Host rebuilt, but incus/gen-tf.sh failed. Check journalctl -u nixos-auto-update" critical
          exit 1
        fi

        plan_rc=0
        tofu -chdir=incus/infra plan -detailed-exitcode -input=false -out=auto.tfplan || plan_rc=$?

        case "$plan_rc" in
          0)
            notify "NixOS Auto Updater" "Host rebuilt; no Incus changes." normal
            ;;
          2)
            if ! unsafe=$(tofu -chdir=incus/infra show -json auto.tfplan | jq -r '
              .resource_changes[]?
              | select((.change.actions | index("delete")) != null)
              | select(
                  (.address | startswith("incus_storage_volume.")) or
                  ((.address | startswith("incus_instance.")) and ((.change.actions | length) == 1)) or
                  (.address | startswith("incus_project.")) or
                  (.address | startswith("incus_network.")) or
                  (.address | startswith("incus_network_forward.")) or
                  (.address | startswith("incus_storage_pool.")) or
                  (.address | startswith("incus_server."))
                )
              | .address
            '); then
              notify "NixOS Auto Updater" "Could not inspect the Incus plan. Check journalctl -u nixos-auto-update" critical
              exit 1
            fi

            if [ -n "$unsafe" ]; then
              notify "NixOS Auto Updater" "Incus plan requires review. Destructive changes blocked: $unsafe. See /etc/nixos/incus/infra/auto.tfplan" critical
            else
              if tofu -chdir=incus/infra apply -parallelism=1 auto.tfplan; then
                systemctl start incus-secrets.service || true
                notify "NixOS Auto Updater" "Incus plan applied successfully." normal
              else
                notify "NixOS Auto Updater" "Incus apply failed. Check journalctl -u nixos-auto-update" critical
                exit 1
              fi
            fi
            ;;
          *)
            notify "NixOS Auto Updater" "Incus plan failed. Check journalctl -u nixos-auto-update" critical
            exit 1
            ;;
        esac
      fi
    '';
  };

  systemd.timers.nixos-auto-update = {
    description = "Hourly timer for NixOS auto-update";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "1h";
      RandomizedDelaySec = "5min";
    };
  };
}
