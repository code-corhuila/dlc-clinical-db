#!/usr/bin/env bash
# Stage deployment check: for dev, qa and prod, starts the dlc-infra-mongo engine (replica set, TLS in
# qa and prod with throwaway certificates), runs the authenticated migrator over clinical-data twice and
# checks identities and network isolation. Test-only secrets and synthetic data; everything is removed.
# Usage: tooling/test-environment-migration.sh [path to dlc-infra-mongo, default ../dlc-infra-mongo] [stages...]
set -euo pipefail
export MSYS_NO_PATHCONV=1

readonly infra="${1:-../dlc-infra-mongo}"
shift || true
[ $# -gt 0 ] || set -- dev qa prod
readonly stages=("$@")
readonly mongo_image='mongo:8.0.32@sha256:4968f22d0c6c10ef29952f3e807f62872ba22b3312f25803564fbfc08255efc2'
readonly run_id="envtest-$$"
readonly work=".test-env/$run_id"
readonly migrate_image="dlc-clinical-db-migrate:$run_id"

test -f "$infra/compose.yml" -a -f "$infra/tests/make-test-certificates.sh" || { echo "dlc-infra-mongo not found at $infra" >&2; exit 2; }
# Docker on Windows needs drive paths; elsewhere the absolute path is used as is.
abs() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$(cd "$1" && pwd)"; else (cd "$1" && pwd); fi; }
readonly infra_dir="$(abs "$infra")"
mkdir -p "$work"
readonly work_dir="$(abs "$work")"

stage_project=''
cleanup() {
  [ -n "$stage_project" ] && infra_compose down -v --remove-orphans >/dev/null 2>&1 || true
  docker network rm "clinical-data-$run_id" "platform-$run_id" >/dev/null 2>&1 || true
  docker image rm -f "$migrate_image" >/dev/null 2>&1 || true
  docker run --rm -v "$work_dir:/w" "$mongo_image" rm -rf /w/secrets >/dev/null 2>&1 || true
  rm -rf "$work"
  rmdir .test-env 2>/dev/null || true
}
trap cleanup EXIT

infra_compose() {
  local files=(-f "$infra_dir/compose.yml")
  [ "$tls" = true ] && files+=(-f "$infra_dir/compose.tls.yml")
  CLINICAL_DATA_NETWORK_NAME="clinical-data-$run_id" \
  DLC_MONGO_ROOT_PASSWORD_FILE="$work_dir/secrets/root" DLC_MONGO_KEYFILE="$work_dir/secrets/keyfile" \
  DLC_CLINICAL_MIGRATOR_PASSWORD_FILE="$work_dir/secrets/migrator" DLC_CLINICAL_RUNTIME_PASSWORD_FILE="$work_dir/secrets/runtime" \
  DLC_CLINICAL_BACKUP_PASSWORD_FILE="$work_dir/secrets/backup" \
  DLC_MONGO_TLS_CERTIFICATE_FILE="$work_dir/secrets/server.pem" DLC_MONGO_TLS_CA_FILE="$work_dir/secrets/ca.pem" \
    docker compose -p "$stage_project" --project-directory "$infra_dir" "${files[@]}" "$@"
}

# The stage runner exactly as documented: compose.yml + compose.auth.yml (+ compose.tls.yml).
migrate() {
  local stage="$1" with_tls="$2"; shift 2
  local files=(-f deploy/compose.yml -f deploy/compose.auth.yml)
  [ "$with_tls" = true ] && files+=(-f deploy/compose.tls.yml)
  DLC_ENVIRONMENT="$stage" MONGO_HOST=dlc-mongo CLINICAL_DATA_NETWORK_NAME="clinical-data-$run_id" \
  CLINICAL_DB_MIGRATE_IMAGE="$migrate_image" MONGO_MIGRATOR_PASSWORD_FILE="$work_dir/secrets/migrator" \
  MONGO_TLS_CA_FILE="$work_dir/secrets/ca.pem" \
    docker compose -p "mig-$run_id" "${files[@]}" --profile tooling run --rm clinical-db-migrate "$@"
}

# mongosh on clinical-data as a Clinical identity; prints the evaluated result.
as_identity() {
  local user="$1" secret="$2" script="$3" options="replicaSet=rs0&authSource=clinical&serverSelectionTimeoutMS=10000"
  [ "$tls" = true ] && options="$options&tls=true&tlsCAFile=/s/ca.pem"
  docker run --rm --network "clinical-data-$run_id" -v "$work_dir/secrets:/s:ro" "$mongo_image" sh -c \
    "mongosh --quiet --norc \"mongodb://$user:\$(cat /s/$secret)@dlc-mongo:27017/clinical?$options\" --eval \"$script\""
}

# The command must fail, and for the expected reason (its output matches the pattern).
expect_refusal() {
  local what="$1" pattern="$2" output; shift 2
  if output=$("$@" 2>&1); then echo "FAIL: $what (accepted)" >&2; exit 1; fi
  grep -Eq "$pattern" <<<"$output" || { echo "FAIL: $what (failed for another reason)" >&2; echo "$output" | tail -5 >&2; exit 1; }
  echo "ok: $what"
}

readonly changesets=$(grep -R --include='*.yaml' -E '^[[:space:]]+id:' 01_ddl 02_dml 03_dcl | wc -l | tr -d ' ')
docker network create "clinical-data-$run_id" >/dev/null
docker network create "platform-$run_id" >/dev/null
CLINICAL_DB_MIGRATE_IMAGE="$migrate_image" MONGO_HOST=dlc-mongo docker compose -p "mig-$run_id" -f deploy/compose.yml --profile tooling build -q clinical-db-migrate

for stage in "${stages[@]}"; do
  echo "== $stage"
  tls=false; [ "$stage" != dev ] && tls=true
  stage_project="infra-$stage-$run_id"
  docker run --rm -v "$work_dir:/w" "$mongo_image" rm -rf /w/secrets >/dev/null
  mkdir -p "$work/secrets"
  # Throwaway CA, certificate (SAN dlc-mongo) and passwords from dlc-infra-mongo; readable by the migrator user.
  docker run --rm -e TLS_HOST=dlc-mongo -v "$work_dir/secrets:/secrets" -v "$infra_dir/tests:/checks:ro" "$mongo_image" sh -c \
    'sh /checks/make-test-certificates.sh && openssl rand -hex 24 > /secrets/runtime && openssl rand -hex 24 > /secrets/backup && chmod 444 /secrets/*'

  infra_compose up -d dlc-mongo >/dev/null
  for i in $(seq 1 40); do infra_compose run --rm dlc-mongo-init >/dev/null 2>&1 && break; [ "$i" = 40 ] && { echo "engine not ready" >&2; exit 1; }; sleep 3; done
  echo "ok: engine and clinical_migrator ready (TLS $tls)"

  expect_refusal "an unknown stage is refused" 'Set DLC_ENVIRONMENT to dev, qa or prod' migrate staging "$tls" update
  [ "$tls" = true ] && expect_refusal "$stage refuses to migrate without TLS" 'TLS is required' migrate "$stage" false update

  migrate "$stage" "$tls" update >/dev/null
  applied=$(as_identity clinical_migrator migrator 'db.databasechangelog_clinical.countDocuments()')
  [ "$applied" = "$changesets" ] || { echo "FAIL: $applied of $changesets changesets applied" >&2; exit 1; }
  echo "ok: clinical_migrator applied $applied changesets"
  migrate "$stage" "$tls" update >/dev/null
  again=$(as_identity clinical_migrator migrator 'db.databasechangelog_clinical.countDocuments()')
  [ "$again" = "$changesets" ] || { echo "FAIL: the second update changed the history ($again)" >&2; exit 1; }
  migrate "$stage" "$tls" status | grep -q 'up to date' || { echo "FAIL: status is not up to date" >&2; exit 1; }
  echo "ok: a second update applies nothing"

  infra_compose --profile identities run --rm dlc-mongo-runtime-identity >/dev/null
  [ "$(as_identity clinical_runtime runtime 'db.schema_info.findOne().version')" = 1 ] || { echo "FAIL: runtime cannot read schema_info" >&2; exit 1; }
  expect_refusal "clinical_runtime cannot run DDL" 'not authorized|Unauthorized' as_identity clinical_runtime runtime 'db.createCollection(\"ddl_probe\")'
  expect_refusal "clinical_runtime cannot read the changelog" 'not authorized|Unauthorized' as_identity clinical_runtime runtime 'db.databasechangelog_clinical.findOne()'

  ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"clinical-data-$run_id\").IPAddress}}" "$(infra_compose ps -q dlc-mongo)")
  expect_refusal "a container outside clinical-data cannot reach MongoDB" 'MongoServerSelectionError|ENOTFOUND|ECONNREFUSED|EAI_AGAIN|timed out' docker run --rm --network "platform-$run_id" "$mongo_image" \
    sh -c "mongosh --quiet --norc 'mongodb://dlc-mongo:27017/?directConnection=true&serverSelectionTimeoutMS=3000' --eval 'db.hello()' || mongosh --quiet --norc 'mongodb://$ip:27017/?directConnection=true&serverSelectionTimeoutMS=3000' --eval 'db.hello()'"

  infra_compose down -v --remove-orphans >/dev/null
  stage_project=''
done
echo "PASS: ${stages[*]}"
