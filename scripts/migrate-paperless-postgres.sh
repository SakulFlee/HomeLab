#!/usr/bin/env bash
# Migrate Paperless from PostgreSQL 18 to 19.
#
# PostgreSQL 18 moved PGDATA to /var/lib/postgresql/<major>/docker, so a major
# upgrade is a data migration, not an image swap. This takes a cold logical
# dump of the 18 cluster, verifies that dump by restoring it into a throwaway
# 19 container, moves the 18 cluster aside, lets the 19 image initialise its own
# major-version directory and restores the dump into it. Row counts are compared
# before and after.
#
# Paperless already mounts /var/lib/postgresql, so unlike Fluxer there is no
# compose change to push: stacks/paperless/compose.yaml already says
# postgres:19-alpine, and the deploy timer is restarted at the end.
#
# Nothing is deleted. The dump goes to /srv/backup/dumps (which restic covers)
# and the 18 cluster is kept at /srv/docker/paperless/postgres-18-pre19.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_root
require_cmd docker
require_cmd jq
require_cmd flock

stack="paperless"
data_dir="${LIVE_DATA_DIR}/paperless/postgres"
archive_dir="${LIVE_DATA_DIR}/paperless/postgres-18-pre19"
dump_dir="${BACKUP_DIR}/dumps"
db_user="paperless"
db_name="paperless"
old_major=18
old_image="postgres:18-alpine"
timer="homelab-deploy.timer"
lock_file="/run/lock/homelab-deploy.lock"

assume_yes=0
for arg in "$@"; do
  case "${arg}" in
    -y|--yes) assume_yes=1 ;;
    -h|--help)
      sed -n '2,16p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown argument: ${arg} (use --help)" ;;
  esac
done

dump=""
moved=0
timer_was_active=0

cleanup() {
  docker rm -f paperless-pg18 paperless-pg19-dryrun >/dev/null 2>&1 || true
}
trap cleanup EXIT

# On any failure, say where the data is and how to get back to a running 18
# stack. The archive and the dump are never removed, so this is a rename away.
on_error() {
  local rc=$?
  printf '\n' >&2
  log "ERROR: migration stopped (exit ${rc})" >&2
  log "dump:       ${dump:-not taken}" >&2
  log "18 cluster: $([[ "${moved}" == 1 ]] && echo "${archive_dir}" || echo "${data_dir}/${old_major} (still in place)")" >&2
  if [[ "${moved}" == 1 ]]; then
    log "roll back with:" >&2
    log "  sudo docker compose --project-directory ${STACKS_DIR}/${stack} -f ${STACKS_DIR}/${stack}/compose.yaml down" >&2
    log "  sudo mv ${data_dir}/19 ${data_dir}/19-aborted" >&2
    log "  sudo mv ${archive_dir} ${data_dir}/${old_major}" >&2
    log "  sudo systemctl start ${timer}" >&2
  else
    log "nothing was moved; start the stack again with ${STACKS_DIR}/${stack}/compose.yaml" >&2
    log "  sudo docker compose --project-directory ${STACKS_DIR}/${stack} -f ${STACKS_DIR}/${stack}/compose.yaml up -d" >&2
  fi
}
trap on_error ERR

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
  local target_major="$1"

  if [[ -s "${data_dir}/${target_major}/docker/PG_VERSION" ]]; then
    log "${data_dir}/${target_major}/docker already holds a cluster; nothing to do"
    exit 0
  fi

  [[ -f "${STACKS_DIR}/${stack}/compose.yaml" ]] || die "missing compose file for ${stack}"
  [[ -d "${data_dir}" ]] || die "missing ${data_dir}"
  [[ ! -e "${archive_dir}" ]] || die "${archive_dir} already exists; resolve that by hand first"
  [[ ! -e "${data_dir}/PG_VERSION" ]] \
    || die "${data_dir} holds a pre-18 layout; this script expects <major>/docker subdirectories"

  local src_ver
  src_ver="$(cat "${data_dir}/${old_major}/docker/PG_VERSION" 2>/dev/null || true)"
  [[ "${src_ver}" == "${old_major}" ]] \
    || die "expected a PostgreSQL ${old_major} cluster in ${data_dir}/${old_major}/docker, found '${src_ver}'"

  if ! git -C "${REPO_ROOT}" diff --quiet \
    || ! git -C "${REPO_ROOT}" diff --cached --quiet; then
    die "working tree is dirty; commit or stash before migrating"
  fi
}

main() {
  # Serialise with deploy.sh: it takes the same lock and skips while we hold it.
  install -d -m 0755 /run/lock
  exec 9>"${lock_file}"
  flock -n 9 || die "a deploy or another migration is running; try again when it finishes"

  local target_image target_major
  target_image="$(compose "${stack}" config --format json 2>/dev/null \
    | jq -r '.services.db.image // empty' || true)"
  target_image="${target_image:-postgres:19-alpine}"
  target_major="${target_image#*:}"
  target_major="${target_major%%-*}"
  [[ "${target_major}" =~ ^[0-9]+$ ]] || die "cannot derive the major version from ${target_image}"

  preflight "${target_major}"

  printf '\n'
  log "this will:"
  log "  - stop the Paperless stack (downtime until the restore finishes)"
  log "  - dump ${data_dir} to ${dump_dir}"
  log "  - verify the dump in a throwaway ${target_image} container"
  log "  - move the ${old_major} cluster to ${archive_dir}"
  log "  - create a fresh ${target_major} cluster and restore the dump into it"
  log "  - restart ${timer} afterwards (no compose change is needed)"
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

  # 1. Stop the stack and start the 18 cluster in a throwaway container.
  log "[1/8] stopping the Paperless stack"
  compose "${stack}" stop

  log "[2/8] starting the ${old_major} cluster for the dump"
  docker rm -f paperless-pg18 >/dev/null 2>&1 || true
  docker run -d --name paperless-pg18 \
    -v "${data_dir}:/var/lib/postgresql" \
    "${old_image}" >/dev/null
  wait_ready paperless-pg18 || die "the ${old_major} cluster did not become ready"
  [[ "$(server_version_num paperless-pg18)" == "${old_major}"* ]] || die "unexpected source version"

  local extensions
  extensions="$(docker exec paperless-pg18 psql -U "${db_user}" -d "${db_name}" -At -c \
    "select extname from pg_extension where extname <> 'plpgsql'")"
  if [[ -n "${extensions}" ]]; then
    log "extensions in the ${old_major} cluster: $(tr '\n' ' ' <<<"${extensions}")"
  fi

  # 3. Dump and check the archive.
  log "[3/8] dumping the ${old_major} cluster"
  install -d -m 0755 "${dump_dir}"
  dump="${dump_dir}/paperless-pre${target_major}-$(date +%Y%m%dT%H%M%S).dump"
  docker exec paperless-pg18 pg_dump -Fc -U "${db_user}" -d "${db_name}" > "${dump}"
  [[ -s "${dump}" ]] || die "dump is empty: ${dump}"
  local entries
  entries="$(docker run --rm -v "${dump_dir}:/dumps:ro" "${old_image}" \
    sh -c "pg_restore -l /dumps/$(basename "${dump}")" | grep -c 'TABLE DATA' || true)"
  (( entries > 0 )) || die "dump contains no table data: ${dump}"
  log "wrote ${dump} ($(du -h "${dump}" | cut -f1), ${entries} table data entries)"

  local counts_before="${STATE_DIR}/paperless-pre${target_major}-counts-before.txt"
  install -d -m 0755 "${STATE_DIR}"
  row_counts paperless-pg18 > "${counts_before}"

  docker rm -f paperless-pg18 >/dev/null

  # 4. Prove the dump restores into the new major before touching anything.
  log "[4/8] verifying the dump in a throwaway ${target_major} container"
  docker rm -f paperless-pg19-dryrun >/dev/null 2>&1 || true
  docker run -d --name paperless-pg19-dryrun \
    -e POSTGRES_PASSWORD=dryrun \
    -e POSTGRES_USER="${db_user}" \
    -e POSTGRES_DB="${db_name}" \
    -v "${dump_dir}:/dumps:ro" \
    "${target_image}" >/dev/null
  wait_ready paperless-pg19-dryrun || die "the throwaway ${target_major} container did not become ready"
  [[ "$(server_version_num paperless-pg19-dryrun)" == "${target_major}"* ]] \
    || die "expected ${target_image} to be PostgreSQL ${target_major}"

  local ext
  for ext in ${extensions}; do
    docker exec paperless-pg19-dryrun psql -U "${db_user}" -d "${db_name}" -At -c \
      "select 1 from pg_available_extensions where name = '${ext}'" | grep -q 1 \
      || die "extension '${ext}' is not available in ${target_image}"
  done

  docker exec paperless-pg19-dryrun pg_restore -U "${db_user}" -d "${db_name}" \
    --no-owner --no-acl --exit-on-error "/dumps/$(basename "${dump}")"

  if ! row_counts paperless-pg19-dryrun > "${STATE_DIR}/paperless-pre${target_major}-counts-dryrun.txt"; then
    die "could not read row counts from the throwaway container"
  fi
  diff -u "${counts_before}" "${STATE_DIR}/paperless-pre${target_major}-counts-dryrun.txt" >/dev/null \
    || die "row counts differ in the dry run; nothing was changed (dump: ${dump})"
  log "dry run matches: $(wc -l < "${counts_before}") tables"

  docker rm -f paperless-pg19-dryrun >/dev/null

  # 5. Move the old cluster out of the mount, leaving the mount root empty.
  log "[5/8] moving the ${old_major} cluster to ${archive_dir}"
  mv "${data_dir}/${old_major}" "${archive_dir}"
  moved=1
  install -d -m 0700 -o 70 -g 70 "${data_dir}"

  # 6. Initialise the new major on the same mount.
  log "[6/8] initialising the ${target_major} cluster"
  compose "${stack}" up -d --wait --wait-timeout 180 db
  [[ "$(server_version_num paperless-db)" == "${target_major}"* ]] \
    || die "paperless-db is not running ${target_major}"
  docker inspect paperless-db \
    --format '{{range .Mounts}}{{println .Destination}}{{end}}' \
    | grep -qx '/var/lib/postgresql' \
    || die "paperless-db is not mounted at /var/lib/postgresql"

  # 7. Restore and verify against the pre-migration counts.
  log "[7/8] restoring the dump"
  docker exec -i paperless-db pg_restore -U "${db_user}" -d "${db_name}" \
    --no-owner --no-acl --exit-on-error < "${dump}"

  if ! row_counts paperless-db > "${STATE_DIR}/paperless-pre${target_major}-counts-after.txt"; then
    die "could not read row counts after the restore"
  fi
  if ! diff -u "${counts_before}" "${STATE_DIR}/paperless-pre${target_major}-counts-after.txt"; then
    die "row counts differ after the restore; the ${old_major} cluster is at ${archive_dir} and the dump at ${dump}"
  fi
  log "restore matches: $(wc -l < "${counts_before}") tables"

  # 8. Bring the rest of the stack up.
  log "[8/8] starting the Paperless stack"
  compose "${stack}" up -d --wait --wait-timeout 600
  "${SCRIPT_DIR}/healthcheck.sh" || log "WARN: healthcheck reported failures; inspect the Paperless logs"

  if (( timer_was_active )); then
    log "restarting ${timer}"
    systemctl start "${timer}"
  fi

  log "migration complete"
  log "dump:        ${dump}"
  log "old cluster: ${archive_dir} (kept; move it to ${BACKUP_DIR} when confident)"

  cat <<EOF

Paperless is on PostgreSQL ${target_major}. No compose change is needed: main
already pins postgres:${target_major}-alpine.

Next steps:

1. Check Paperless (login, documents, search, a consume).

2. Move the old cluster out of the restic data set and delete it when ready:

     sudo mv ${archive_dir} ${BACKUP_DIR}/

EOF
}

main "$@"
