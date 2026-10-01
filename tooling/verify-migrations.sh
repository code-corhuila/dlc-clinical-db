#!/usr/bin/env bash
set -euo pipefail

readonly mongo_image='mongo@sha256:4968f22d0c6c10ef29952f3e807f62872ba22b3312f25803564fbfc08255efc2'
readonly run_id="${GITHUB_RUN_ID:-local}-$$"
readonly mongo_name="clinical-ci-mongo-${run_id}"
readonly network_name="clinical-ci-platform-${run_id}"

cleanup() {
  docker rm -f "$mongo_name" >/dev/null 2>&1 || true
  docker network rm "$network_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if docker container inspect "$mongo_name" >/dev/null 2>&1 || docker network inspect "$network_name" >/dev/null 2>&1; then
  echo 'Refusing to reuse an existing test resource.' >&2
  exit 1
fi

for _ in $(seq 1 3); do
  docker network create "$network_name" >/dev/null && break
  sleep 1
done
docker network inspect "$network_name" >/dev/null
docker run -d --name "$mongo_name" --network "$network_name" "$mongo_image" mongod --replSet rs0 --bind_ip_all >/dev/null
for _ in $(seq 1 30); do
  docker exec "$mongo_name" mongosh --quiet --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -qx 1 && break
  sleep 1
done
docker exec "$mongo_name" mongosh --quiet --eval 'db.adminCommand({ping:1}).ok' | grep -qx 1
docker exec "$mongo_name" mongosh --quiet --eval "rs.initiate({_id:'rs0',members:[{_id:0,host:'$mongo_name:27017'}]})" >/dev/null || true
for _ in $(seq 1 30); do
  docker exec "$mongo_name" mongosh --quiet --eval 'db.hello().isWritablePrimary ? 1 : 0' | grep -qx 1 && break
  sleep 1
done
docker exec "$mongo_name" mongosh --quiet --eval 'db.hello().isWritablePrimary ? 1 : 0' | grep -qx 1

run_migrator() {
  MONGO_HOST="$mongo_name" MONGO_PORT=27017 CLINICAL_DB_NAME=clinical MONGO_REPLICA_SET=rs0 PLATFORM_NETWORK_NAME="$network_name" \
    docker compose -f deploy/compose.yml --profile tooling run --rm clinical-db-migrate \
      --database-changelog-table-name=databasechangelog_clinical \
      --database-changelog-lock-table-name=databasechangeloglock_clinical "$@"
}

MONGO_HOST="$mongo_name" MONGO_PORT=27017 CLINICAL_DB_NAME=clinical MONGO_REPLICA_SET=rs0 PLATFORM_NETWORK_NAME="$network_name" \
  docker compose -f deploy/compose.yml --profile tooling build clinical-db-migrate

run_migrator update
run_migrator update
run_migrator status --verbose
run_migrator history
run_migrator validate

mongo_eval() { docker exec "$mongo_name" mongosh --quiet clinical --eval "$1"; }
mongo_eval "for (const n of ['databasechangelog_clinical','databasechangeloglock_clinical']) if (!db.getCollectionNames().includes(n)) throw new Error('missing control '+n)"
mongo_eval "const d={_id:'record-1',clinicalRecordId:'record-1',patientId:'patient-1',version:1,createdAt:new Date(),updatedAt:new Date(),createdBy:'dentist-1'}; db.clinical_records.insertOne(d); for (const [x,m] of [[{...d,_id:'record-2',clinicalRecordId:'record-2',patientId:'patient-2',unknown:true},'undeclared'],[{_id:'record-3'},'required'],[{...d,_id:'record-4',clinicalRecordId:'record-4'},'unique']]) { try { db.clinical_records.insertOne(x); throw new Error(m+' accepted') } catch(e) { if(e.message.includes(m+' accepted')) throw e } }"
mongo_eval "const d={_id:'entry-1',entryId:'entry-1',clinicalRecordId:'record-1',kind:'EVOLUTION',text:'ok',authorId:'dentist-1',createdAt:new Date(),updatedAt:new Date(),version:1}; db.clinical_entries.insertOne(d); try { db.clinical_entries.insertOne({...d,_id:'entry-2',entryId:'entry-2',kind:'INVALID'}); throw new Error('enum accepted') } catch(e) { if(e.message.includes('enum accepted')) throw e }"
mongo_eval "const procedures=Array.from({length:101},(_,i)=>({procedureId:'p'+i,procedureCode:'code',appointmentId:'a',status:'PLANNED'})); try { db.treatments.insertOne({_id:'treatment-1',treatmentId:'treatment-1',clinicalRecordId:'record-1',patientId:'patient-1',status:'PLANNED',procedures,createdAt:new Date(),updatedAt:new Date(),version:1}); throw new Error('maxItems accepted') } catch(e) { if(e.message.includes('maxItems accepted')) throw e }"
mongo_eval "for (const [c,i] of [['clinical_records','uq_clinical_records_patient_id'],['clinical_entries','uq_clinical_entries_entry_id'],['outbox_events','idx_outbox_events_publish_work']]) if (!db.getCollection(c).getIndexes().some(x=>x.name===i)) throw new Error('missing index '+i); for (const r of ['clinical_application','clinical_inbox_consumer','clinical_outbox_publisher']) { const role=db.getRole(r,{showPrivileges:true}); if (!role || !role.privileges.length || role.privileges.some(p=>p.resource.db!=='clinical')) throw new Error('invalid role '+r) }"

changeset_count=$(grep -R --include='*.yaml' -E '^[[:space:]]+id:' 01_ddl 02_dml 03_dcl | wc -l | tr -d ' ')
test "$changeset_count" -gt 0
run_migrator rollback-count "$changeset_count"
mongo_eval "for (const n of ['clinical_records','clinical_entries','treatments']) if (db.getCollectionNames().includes(n)) throw new Error('rollback retained '+n)"
run_migrator update
run_migrator validate
