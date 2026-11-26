#!/usr/bin/env bash
# Migrate the Fluxer stack from PostgreSQL 16 to 19.
#
# PostgreSQL 18 moved PGDATA to /var/lib/postgresql/<major>/docker and expects
# the mount one level up, so a 16 data directory cannot be opened in place. This
# takes a cold logical dump of the 16 cluster, verifies that dump by restoring
# it into a throwaway 19 container, renames the old cluster aside, initialises a
# fresh 19 cluster on the new mount and restores the dump into it. Row counts
# are compared before and after.
#
# Nothing is deleted. The dump goes to /srv/backup/dumps (which restic covers)
# and the 16 cluster is kept at /srv/docker/fluxer/postgres-16-pre19.
#
# The repository files are NOT modified: compose is run with a temporary
# override so the checkout stays clean and deploy.sh can still fast-forward.
# Apply the same two-line change from your workstation and push (the script
# prints the diff), then restart the timer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_root
require_cmd docker
require_cmd jq

stack_dir="${STACKS_DIR}/fluxer"
compose_file="${stack_dir}/compose.yaml"
override_file="${stack_dir}/compose.override.yaml"
env_file="${RUNTIME_SECRETS_DIR}/fluxer.env"
data_dir="${LIVE_DATA_DIR}/fluxer/postgres-data"
archive_dir="${LIVE_DATA_DIR}/fluxer/postgres-16-pre19"
dump_dir="${BACKUP_DIR}/dumps"
db_user="fluxer"
db_name="fluxer"
old_image="postgres:16-alpine"
timer="homelab-deploy.timer"

assume_yes=0
for arg in "$@"; do
  case "${arg}" in
    -y|--yes) assume_yes=1 ;;
    -h|--help)
      sed -n '2,17p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown argument: ${arg} (use --help)" ;;
  esac
done

tmp_override=""
timer_was_active=0
dump=""
moved=0

cleanup() {
  docker rm -f fluxer-pg16 fluxer-pg19-dryrun >/dev/null 2>&1 || true
  if [[ -n "${tmp_override}" ]]; then
    rm -f "${tmp_override}"
    rmdir "$(dirname "${tmp_override}")" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# On any failure, say where the data is and how to get back to a running 16
# stack. The archive and the dump are never removed, so this is a rename away.
on_error() {
  local rc=$?
  printf '\n' >&2
  log "ERROR: migration stopped (exit ${rc})" >&2
  log "dump:       ${dump:-not taken}" >&2
  log "16 cluster: $([[ "${moved}" == 1 ]] && echo "${archive_dir}" || echo "${data_dir} (still in place)")" >&2
  if [[ "${moved}" == 1 ]]; then
    log "roll back with:" >&2
    log "  sudo docker compose --project-directory ${stack_dir} -f ${compose_file} --env-file ${env_file} down" >&2
    log "  sudo mv ${data_dir} ${LIVE_DATA_DIR}/fluxer/postgres-19-aborted" >&2
    log "  sudo mv ${archive_dir} ${data_dir}" >&2
    log "  sudo systemctl start ${timer}   # once the compose files are unchanged" >&2
  else
    log "nothing was moved; start the stack again with ${stack_dir}/compose.sh up -d" >&2
  fi
}
trap on_error ERR

# Compose calls during the migration use a throwaway override for the mount, so
# the repository never has to be dirty while the timer is off.
mig_compose() {
  docker compose \
    --project-directory "${stack_dir}" \
    -f "${compose_file}" \
    -f "${tmp_override}" \
    --env-file "${env_file}" \
    "$@"
}

wait_ready() {
  local ctr="$1" i
  for i in $(seq 1 60); do
    if docker exec "${ctr}" pg_isready -U "${db_user}" -q; then
      return 0
    fi
    sleep 1
  done
  return 1
}

server_version_num() {
  docker exec "$1" psql -U "${db_user}" -d "${db_name}" -At -c 'show server_version_num'
}

# One line per table: "<schema>.<table>|<count>", sorted so the two sides of a
# comparison are independent of catalog order.
row_counts() {
  local ctr="$1" query
  query="$(docker exec "${ctr}" psql -U "${db_user}" -d "${db_name}" -At -c \
    "select string_agg(
       format('select %L as t, count(*) as c from %I.%I', schemaname || '.' || tablename, schemaname, tablename),
       ' union all ')
     from pg_tables
     where schemaname not in ('pg_catalog', 'information_schema')")"
  [[ -n "${query}" ]] || return 1
  docker exec "${ctr}" psql -U "${db_user}" -d "${db_name}" -At -F'|' -c "${query}" | sort
}

preflight() {
  if [[ -s "${data_dir}/19/docker/PG_VERSION" ]]; then
    log "${data_dir}/19/docker already holds a cluster; nothing to do"
    exit 0
  fi

  [[ -f "${compose_file}" ]] || die "missing ${compose_file}"
  [[ -f "${override_file}" ]] || die "missing ${override_file}"
  [[ -f "${env_file}" ]] || die "missing ${env_file}; run scripts/render-secrets.sh"
  [[ -d "${data_dir}" ]] || die "missing ${data_dir}"
  [[ ! -e "${archive_dir}" ]] || die "${archive_dir} already exists; resolve that by hand first"
  [[ ! -e "${data_dir}/19" ]] || die "${data_dir}/19 already exists; this looks partially migrated"

  local src_ver
  src_ver="$(cat "${data_dir}/PG_VERSION" 2>/dev/null || true)"
  [[ "${src_ver}" == "16" ]] \
    || die "expected a PostgreSQL 16 cluster in ${data_dir}, found '${src_ver}'"

  if ! git -C "${REPO_ROOT}" diff --quiet \
    || ! git -C "${REPO_ROOT}" diff --cached --quiet; then
    die "working tree is dirty; commit or stash before migrating"
  fi

  # The compose files must still describe the old mount, otherwise there is
  # nothing to do or something else already changed them.
  grep -q 'var/lib/postgresql/data' "${compose_file}" \
    && grep -q 'var/lib/postgresql/data' "${override_file}" \
    || die "compose files no longer use the pre-18 mount; inspect them before running this"
}

main() {
  preflight

  local target_image
  target_image="$(compose fluxer config --format json 2>/dev/null \
    | jq -r '.services.postgres.image // empty' || true)"
  target_image="${target_image:-postgres:19-alpine}"

  printf '\n'
  log "this will:"
  log "  - stop the Fluxer stack (downtime until the restore finishes)"
  log "  - dump ${data_dir} to ${dump_dir}"
  log "  - verify the dump in a throwaway ${target_image} container"
  log "  - move the 16 cluster to ${archive_dir}"
  log "  - create a fresh 19 cluster and restore the dump into it"
  log "  - leave ${timer} stopped until the compose change is pushed"
  printf '\n'
  if (( ! assume_yes )); then
    local answer
    read -r -p "Type 'migrate' to continue: " answer
    [[ "${answer}" == 'migrate' ]] || die "aborted"
  fi

  if systemctl is-active --quiet "${timer}"; then
    timer_was_active=1
    log "stopping ${timer}"
    systemctl stop "${timer}"
  fi

  tmp_override="$(mktemp -d /tmp/fluxer-pg19.XXXXXXXX)/override.yaml"
  printf 'services:\n  postgres:\n    volumes: !override\n      - %s:/var/lib/postgresql\n' \
    "${data_dir}" > "${tmp_override}"

  # 1. Stop the stack and start the 16 cluster in a throwaway container.
  log "[1/8] stopping the Fluxer stack"
  compose fluxer stop

  log "[2/8] starting the 16 cluster for the dump"
  docker rm -f fluxer-pg16 >/dev/null 2>&1 || true
  docker run -d --name fluxer-pg16 \
    -v "${data_dir}:/var/lib/postgresql/data" \
    "${old_image}" >/dev/null
  wait_ready fluxer-pg16 || die "the 16 cluster did not become ready"
  [[ "$(server_version_num fluxer-pg16)" == 16* ]] || die "unexpected source version"

  local extensions
  extensions="$(docker exec fluxer-pg16 psql -U "${db_user}" -d "${db_name}" -At -c \
    "select extname from pg_extension where extname <> 'plpgsql'")"
  if [[ -n "${extensions}" ]]; then
    log "extensions in the 16 cluster: $(tr '\n' ' ' <<<"${extensions}")"
  fi

  # 3. Dump and check the archive.
  log "[3/8] dumping the 16 cluster"
  install -d -m 0755 "${dump_dir}"
  dump="${dump_dir}/fluxer-pre19-$(date +%Y%m%dT%H%M%S).dump"
  docker exec fluxer-pg16 pg_dump -Fc -U "${db_user}" -d "${db_name}" > "${dump}"
  [[ -s "${dump}" ]] || die "dump is empty: ${dump}"
  local entries
  entries="$(docker run --rm -v "${dump_dir}:/dumps:ro" "${old_image}" \
    sh -c "pg_restore -l /dumps/$(basename "${dump}")" | grep -c 'TABLE DATA' || true)"
  (( entries > 0 )) || die "dump contains no table data: ${dump}"
  log "wrote ${dump} ($(du -h "${dump}" | cut -f1), ${entries} table data entries)"

  local counts_before="${STATE_DIR}/fluxer-pre19-counts-before.txt"
  install -d -m 0755 "${STATE_DIR}"
  row_counts fluxer-pg16 > "${counts_before}"

  docker rm -f fluxer-pg16 >/dev/null

  # 4. Prove the dump restores into 19 before touching anything.
  log "[4/8] verifying the dump in a throwaway 19 container"
  docker rm -f fluxer-pg19-dryrun >/dev/null 2>&1 || true
  docker run -d --name fluxer-pg19-dryrun \
    -e POSTGRES_PASSWORD=dryrun \
    -e POSTGRES_USER="${db_user}" \
    -e POSTGRES_DB="${db_name}" \
    -v "${dump_dir}:/dumps:ro" \
    "${target_image}" >/dev/null
  wait_ready fluxer-pg19-dryrun || die "the throwaway 19 container did not become ready"
  [[ "$(server_version_num fluxer-pg19-dryrun)" == 19* ]] \
    || die "expected ${target_image} to be PostgreSQL 19"

  local ext
  for ext in ${extensions}; do
    docker exec fluxer-pg19-dryrun psql -U "${db_user}" -d "${db_name}" -At -c \
      "select 1 from pg_available_extensions where name = '${ext}'" | grep -q 1 \
      || die "extension '${ext}' is not available in ${target_image}"
  done

  docker exec fluxer-pg19-dryrun pg_restore -U "${db_user}" -d "${db_name}" \
    --no-owner --no-acl --exit-on-error "/dumps/$(basename "${dump}")"

  if ! row_counts fluxer-pg19-dryrun > "${STATE_DIR}/fluxer-pre19-counts-dryrun.txt"; then
    die "could not read row counts from the throwaway container"
  fi
  diff -u "${counts_before}" "${STATE_DIR}/fluxer-pre19-counts-dryrun.txt" >/dev/null \
    || die "row counts differ in the dry run; nothing was changed (dump: ${dump})"
  log "dry run matches: $(wc -l < "${counts_before}") tables"

  docker rm -f fluxer-pg19-dryrun >/dev/null

  # 5. Move the 16 cluster out of the mount and create a clean mount root.
  log "[5/8] moving the 16 cluster to ${archive_dir}"
  mv "${data_dir}" "${archive_dir}"
  moved=1
  install -d -m 0700 -o 70 -g 70 "${data_dir}"

  # 6. Initialise 19 on the new mount.
  log "[6/8] initialising the 19 cluster"
  mig_compose up -d --wait --wait-timeout 180 postgres
  [[ "$(server_version_num fluxer-postgres)" == 19* ]] || die "fluxer-postgres is not running 19"
  docker inspect fluxer-postgres \
    --format '{{range .Mounts}}{{println .Destination}}{{end}}' \
    | grep -qx '/var/lib/postgresql' \
    || die "fluxer-postgres is not mounted at /var/lib/postgresql"

  # 7. Restore and verify against the pre-migration counts.
  log "[7/8] restoring the dump"
  docker exec -i fluxer-postgres pg_restore -U "${db_user}" -d "${db_name}" \
    --no-owner --no-acl --exit-on-error < "${dump}"

  if ! row_counts fluxer-postgres > "${STATE_DIR}/fluxer-pre19-counts-after.txt"; then
    die "could not read row counts after the restore"
  fi
  if ! diff -u "${counts_before}" "${STATE_DIR}/fluxer-pre19-counts-after.txt"; then
    die "row counts differ after the restore; the 16 cluster is at ${archive_dir} and the dump at ${dump}"
  fi
  log "restore matches: $(wc -l < "${counts_before}") tables"

  # 8. Bring the rest of the stack up.
  log "[8/8] starting the Fluxer stack"
  mig_compose up -d --wait --wait-timeout 600
  "${SCRIPT_DIR}/healthcheck.sh" || log "WARN: healthcheck reported failures; inspect the Fluxer logs"

  log "migration complete"
  log "dump:        ${dump}"
  log "old cluster: ${archive_dir} (kept; move it to ${BACKUP_DIR} when confident)"
  if (( timer_was_active )); then
    log "${timer}: stopped"
  else
    log "${timer}: was already inactive"
  fi

  cat <<EOF

Next steps, in this order:

1. On your workstation, apply the same mount change and push it:

     sed -i 's|target: /var/lib/postgresql/data\$|target: /var/lib/postgresql|' \\
       stacks/fluxer/compose.yaml
     sed -i 's|fluxer/postgres-data:/var/lib/postgresql/data|fluxer/postgres-data:/var/lib/postgresql|' \\
       stacks/fluxer/compose.override.yaml
     git commit -am 'fluxer: mount PostgreSQL 19 at /var/lib/postgresql' && git push

2. On the host, once that has landed, restart the timer:

     sudo systemctl start ${timer}

3. Check Fluxer (login, messages, media), then move the old cluster out of the
   restic data set and delete it when you are ready:

     sudo mv ${archive_dir} ${BACKUP_DIR}/

EOF
}

main "$@"
