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

mongo_eval "const d={_id:'k-1',actorId:'dentist-1',operation:'ClinicalOpenclinicalrecord',idempotencyKey:'11111111-1111-4111-8111-111111111111',requestHash:'a'.repeat(64),resourceId:'record-1',responseStatus:201,createdAt:new Date(),expiresAt:new Date(Date.now()+864e5)}; db.idempotency_keys.insertOne(d); for (const [x,m] of [[{...d,_id:'k-2'},'unique'],[{...d,_id:'k-3',idempotencyKey:'short'},'minLength'],[{...d,_id:'k-4',requestHash:'abc'},'hash'],[{...d,_id:'k-5',idempotencyKey:'22222222-2222-4222-8222-222222222222',responseStatus:500},'status'],[{...d,_id:'k-6',idempotencyKey:'33333333-3333-4333-8333-333333333333',extra:1},'undeclared']]) { try { db.idempotency_keys.insertOne(x); throw new Error(m+' accepted') } catch(e) { if(e.message.includes(m+' accepted')) throw e } }"
mongo_eval "const ttl=db.idempotency_keys.getIndexes().find(x=>x.name==='idx_idempotency_keys_expires_at'); if (!ttl || ttl.expireAfterSeconds!==0) throw new Error('missing TTL index'); if (!db.idempotency_keys.getIndexes().some(x=>x.name==='uq_idempotency_keys_scope' && x.unique)) throw new Error('missing scope index'); const p=db.getRole('clinical_application',{showPrivileges:true}).privileges.find(x=>x.resource.collection==='idempotency_keys'); if (!p || !['find','insert'].every(a=>p.actions.includes(a)) || p.actions.includes('remove')) throw new Error('clinical_application lacks idempotency privileges')"
mongo_eval "const d={_id:'x-1',sourceRecordId:'x-1',procedureId:'p-1',appointmentId:'a-1',type:'ADDITIONAL_MATERIAL',quantity:NumberDecimal('1.5'),description:'Resina',clinicalReason:'Fractura',authorId:'dentist-1',createdAt:new Date()}; db.procedure_extras.insertOne(d); for (const [x,m] of [[{...d,_id:'x-2',sourceRecordId:'x-2',type:'MATERIAL'},'legacy enum'],[{...d,_id:'x-3',sourceRecordId:'x-3',description:'d'.repeat(501)},'description length'],[{...d,_id:'x-4',sourceRecordId:'x-4',quantity:NumberDecimal('0')},'zero quantity'],[{...d,_id:'x-5',sourceRecordId:'x-5',unitPrice:1},'money field']]) { try { db.procedure_extras.insertOne(x); throw new Error(m+' accepted') } catch(e) { if(e.message.includes(m+' accepted')) throw e } }"

mongo_eval "const d={_id:'dg-1',diagnosisId:'dg-1',clinicalRecordId:'record-1',dentistId:'dentist-1',consultationId:'c-1',appointmentId:'a-1',code:'K02.1',text:'Caries',createdAt:new Date(),updatedAt:new Date(),version:1}; db.diagnoses.insertOne(d); try { const {consultationId,...x}=d; db.diagnoses.insertOne({...x,_id:'dg-2',diagnosisId:'dg-2'}); throw new Error('diagnosis without consultation accepted') } catch(e) { if(e.message.includes('accepted')) throw e }; if (!db.diagnoses.getIndexes().some(i=>i.name==='idx_diagnoses_consultation_id')) throw new Error('missing index idx_diagnoses_consultation_id')"

mongo_eval "const c={_id:'c-9',consultationId:'c-9',clinicalRecordId:'record-1',dentistId:'dentist-1',code:'CONS-1',text:'ok',createdAt:new Date(),updatedAt:new Date(),version:1}; db.consultations.insertOne(c); const o={_id:'ev-9',eventId:'ev-9',eventType:'ConsultationRecorded',eventVersion:'1',aggregateId:'record-1',aggregateType:'ClinicalRecord',actorUserId:'dentist-1',correlationId:'corr',causationId:'corr',payload:{consultationId:'c-9'},occurredAt:new Date(),status:'PENDING',attempts:0,createdAt:new Date()}; db.outbox_events.insertOne(o); try { db.outbox_events.insertOne({...o,_id:'ev-10',eventId:'ev-10',clinicalText:'x'}); throw new Error('undeclared outbox field accepted') } catch(e) { if(e.message.includes('accepted')) throw e }"

mongo_eval "const t={_id:'tr-9',treatmentId:'tr-9',clinicalRecordId:'record-1',patientId:'patient-1',clinicalReason:'r',status:'PLANNED',procedures:[{procedureId:'p-9',procedureCode:'OPER',appointmentId:'a',status:'PLANNED'}],createdBy:'dentist-1',createdAt:new Date(),updatedAt:new Date(),version:1}; db.treatments.insertOne(t); try { const {createdBy,...x}=t; db.treatments.insertOne({...x,_id:'tr-10',treatmentId:'tr-10'}); throw new Error('treatment without author accepted') } catch(e) { if(e.message.includes('accepted')) throw e }"

mongo_eval "const c={_id:'cc-1',closureId:'cc-1',clinicalRecordId:'record-1',consultationId:'c-1',appointmentId:'a-1',patientId:'patient-1',dentistId:'dentist-1',procedureIds:['p-1'],manualChargeIds:[],status:'AWAITING_ADMINISTRATIVE_FINALIZATION',appointmentOutcome:'PENDING',billingOutcome:'PENDING',correlationId:'corr',causationId:'corr',completedAt:new Date(),clinicalVersion:2,createdAt:new Date(),updatedAt:new Date(),version:1}; db.care_closures.insertOne(c); for (const [x,m] of [[{...c,_id:'cc-2',closureId:'cc-2'},'encounter unique'],[{...c,_id:'cc-3',closureId:'cc-3',consultationId:'c-3',procedureId:'p-1'},'legacy procedureId'],[{...c,_id:'cc-4',closureId:'cc-4',consultationId:'c-4',status:'OPEN'},'status enum'],[{...c,_id:'cc-5',closureId:'cc-5',consultationId:'c-5',procedureIds:['p','p']},'duplicate procedure']]) { try { db.care_closures.insertOne(x); throw new Error(m+' accepted') } catch(e) { if(e.message.includes(' accepted')) throw e } }; if (!db.care_closures.getIndexes().some(i=>i.name==='uq_care_closures_encounter' && i.unique)) throw new Error('missing uq_care_closures_encounter'); if (db.care_closures.getIndexes().some(i=>i.name==='uq_care_closures_procedure_id')) throw new Error('per-procedure index still present')"

mongo_eval "const op='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; const w={_id:op,operationId:op,kind:'GUARDED_WRITE',patientId:'patient-1',clinicalRecordId:'record-1',state:'PENDING',createdAt:new Date(),updatedAt:new Date()}; db.write_intents.insertOne(w); for (const [x,m] of [[{...w,_id:'w-2'},'operation unique'],[{...w,_id:'w-3',operationId:'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',kind:'OTHER'},'kind enum'],[{...w,_id:'w-4',operationId:'cccccccc-cccc-4ccc-8ccc-cccccccccccc',state:'DONE'},'state enum'],[{_id:'w-5',operationId:'dddddddd-dddd-4ddd-8ddd-dddddddddddd'},'required'],[{...w,_id:'w-6',operationId:'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',amount:10},'money field'],[{...w,_id:'w-7',operationId:'not-a-uuid'},'uuid pattern']]) { try { db.write_intents.insertOne(x); throw new Error(m+' accepted') } catch(e) { if(e.message.includes(' accepted')) throw e } }; const a={_id:'adm-1',clinicalRecordId:'record-1',consultationId:'c-1',admissionState:'OPEN',admissions:[{operationId:op,state:'ADMITTED'}],createdAt:new Date(),updatedAt:new Date(),version:1}; db.encounter_admissions.insertOne(a); for (const [x,m] of [[{...a,_id:'adm-2'},'encounter unique'],[{...a,_id:'adm-3',consultationId:'c-3',admissionState:'CLOSED'},'admission enum'],[{...a,_id:'adm-4',consultationId:'c-4',admissions:[{operationId:op,state:'PENDING'}]},'entry enum'],[{...a,_id:'adm-5',consultationId:'c-5',price:1},'money field']]) { try { db.encounter_admissions.insertOne(x); throw new Error(m+' accepted') } catch(e) { if(e.message.includes(' accepted')) throw e } }; for (const [c,i] of [['write_intents','uq_write_intents_operation_id'],['write_intents','idx_write_intents_reconciliation'],['encounter_admissions','uq_encounter_admissions_encounter'],['encounter_admissions','idx_encounter_admissions_operation_id']]) if (!db.getCollection(c).getIndexes().some(x=>x.name===i)) throw new Error('missing index '+i); for (const c of ['write_intents','encounter_admissions']) { if (db.getCollection(c).getIndexes().some(x=>'expireAfterSeconds' in x)) throw new Error('TTL index on '+c); const p=db.getRole('clinical_application',{showPrivileges:true}).privileges.find(x=>x.resource.collection===c); if (!p || !['find','insert','update'].every(y=>p.actions.includes(y)) || p.actions.some(y=>['remove','createIndex','dropIndex','collMod','dropCollection'].includes(y))) throw new Error('clinical_application privileges on '+c) }"

mongo_eval "const op='abababab-abab-4bab-8bab-abababababab'; db.write_intents.insertOne({_id:op,operationId:op,kind:'GUARDED_WRITE',patientId:'patient-1',fencedAt:new Date(),state:'PENDING',createdAt:new Date(),updatedAt:new Date()}); try { db.write_intents.insertOne({_id:'w-f2',operationId:'acacacac-acac-4cac-8cac-acacacacacac',kind:'GUARDED_WRITE',patientId:'p',fencedAt:'yesterday',state:'PENDING',createdAt:new Date(),updatedAt:new Date()}); throw new Error('string fencedAt accepted') } catch(e) { if(e.message.includes(' accepted')) throw e }"

# Runtime roles: Clinical collections only, no DDL, no role or user management, no deletes by the API (ADR-009).
mongo_eval "const ddl=['createCollection','dropCollection','createIndex','dropIndex','collMod','convertToCapped','renameCollectionSameDB','dropDatabase','createRole','dropRole','grantRole','revokeRole','createUser','dropUser','grantRolesToRole','grantPrivilegesToRole']; for (const r of ['clinical_application','clinical_inbox_consumer','clinical_outbox_publisher']) {  const role=db.getRole(r,{showPrivileges:true}); if (role.roles.length) throw new Error(r+' inherits roles');  for (const p of role.privileges) { if (p.resource.db!=='clinical' || !p.resource.collection) throw new Error(r+' reaches beyond a clinical collection');   const bad=p.actions.filter(a=>ddl.includes(a)); if (bad.length) throw new Error(r+' grants DDL '+bad) } } if (db.getRole('clinical_outbox_publisher',{showPrivileges:true}).privileges.some(p=>p.resource.collection!=='outbox_events')) throw new Error('publisher reaches beyond the outbox'); if (db.getRole('clinical_application',{showPrivileges:true}).privileges.some(p=>p.actions.includes('remove'))) throw new Error('runtime role may delete clinical data')"

changeset_count=$(grep -R --include='*.yaml' -E '^[[:space:]]+id:' 01_ddl 02_dml 03_dcl | wc -l | tr -d ' ')
test "$changeset_count" -gt 0
run_migrator rollback-count "$changeset_count"
mongo_eval "for (const n of ['clinical_records','clinical_entries','treatments','idempotency_keys','write_intents','encounter_admissions']) if (db.getCollectionNames().includes(n)) throw new Error('rollback retained '+n)"
run_migrator update
run_migrator validate


# Upgrade path: migrate an empty store with the previous revision, then apply this one on top of it.
readonly upgrade_from="${UPGRADE_FROM_REF:-origin/develop}"
if git rev-parse --verify --quiet "${upgrade_from}^{commit}" >/dev/null; then
  previous_dir="$(mktemp -d)"
  git worktree add --detach "$previous_dir" "$upgrade_from" >/dev/null
  trap 'git worktree remove --force "$previous_dir" >/dev/null 2>&1 || true; cleanup' EXIT
  run_migrator rollback-count "$changeset_count"
  (
    cd "$previous_dir"
    export COMPOSE_PROJECT_NAME="clinical-previous-${run_id}"
    MONGO_HOST="$mongo_name" PLATFORM_NETWORK_NAME="$network_name" docker compose -f deploy/compose.yml --profile tooling build clinical-db-migrate
    run_migrator update
  )
  docker image rm -f "clinical-previous-${run_id}-clinical-db-migrate" >/dev/null 2>&1 || true
  run_migrator update
  run_migrator validate
  mongo_eval "for (const n of ['write_intents','encounter_admissions','care_closures']) if (!db.getCollectionNames().includes(n)) throw new Error('upgrade missed '+n)"
else
  echo "Upgrade check skipped: $upgrade_from is not available in this checkout." >&2
fi
