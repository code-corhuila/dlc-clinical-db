# dlc-clinical-db

Clinical's MongoDB migration artifact for Di Lucca. It owns only the logical
`clinical` database: collections, validators, indexes, domain roles and
Liquibase changesets. It does not own or run a MongoDB instance, persistent
volume, database users, or another bounded context's data.

The shared MongoDB instance, its volume, environment values and migration
credentials belong to `dlc-infra-mongo`. This repository contributes only the
`clinical-db-migrate` tooling container on the external `platform` network.

## Run migrations

Provide the migration connection contract from `dlc-infra-mongo` (do not commit
it), then run the tooling profile:

```powershell
Copy-Item .env.example .env
# Set MONGO_HOST to the shared MongoDB service name supplied by dlc-infra-mongo.
docker compose -f deploy/compose.yml --profile tooling run --rm clinical-db-migrate
```

The migrator applies `changelog/changelog-master.yaml` in `01_ddl`, `02_dml`,
then `03_dcl` order. It explicitly stores Clinical migration state in
`databasechangelog_clinical` and `databasechangeloglock_clinical`.

`MONGO_HOST`, `MONGO_PORT`, `CLINICAL_DB_NAME`, `MONGO_REPLICA_SET` and
`PLATFORM_NETWORK_NAME` describe the engine.

The `dlc-infra-mongo` engine always requires authentication. Add
`deploy/compose.auth.yml` to run as its migration identity, `clinical_migrator`
(`dbAdmin`, `readWrite` and `userAdmin` on `clinical` only). Its password is read
from the file named by `MONGO_MIGRATOR_PASSWORD_FILE`, which `dlc-infra-mongo`
materializes; it never goes into `.env` or a command line:

```powershell
$env:MONGO_MIGRATOR_PASSWORD_FILE = "<path supplied by dlc-infra-mongo>"
docker compose -f deploy/compose.yml -f deploy/compose.auth.yml --profile tooling run --rm clinical-db-migrate
```

`MONGO_MIGRATOR_USER` overrides the identity name. Without the override file the
migrator connects anonymously, which only the disposable verification below accepts.

## Isolated verification

`tooling/verify-migrations.sh` starts an ephemeral, named MongoDB replica set
without a volume, applies the baseline twice, checks Liquibase control
collections, validators, indexes, roles, rollback and reapply. It never uses
the shared development MongoDB.

```bash
bash tooling/verify-migrations.sh
```

The script removes only the container it creates. Docker and the fixed MongoDB
image must be available. The verification result is evidence for local CI
logic; GitHub Actions itself is not executed locally.

## Structure

```text
01_ddl/  collections, validators, indexes and views
02_dml/  ordered data changes
03_dcl/  password-free Clinical domain roles
changelog/changelog-master.yaml  single entry point
deploy/  Liquibase migrator only (compose.auth.yml adds the migration identity)
tooling/ verification used by CI and local development
```

Applied changesets are immutable. Model changes require a new, documented
changeset; this repository does not define cross-domain writes or direct
cross-domain data access.

## Schema version

`schema_info` holds one row, `{_id: "clinical", version: N}`, readable by the runtime role and written only by
migrations. Every `dlc-clinical-api` process reads it at startup and refuses to run below the version it requires,
so a database without the unique indexes behind "one record per patient" or "one closure per encounter" is never
served. A migration the services depend on raises the version with a changeset in `02_dml/01_updates` and is
released together with the API that requires it. Version 1 covers `clinical-001` to `clinical-027`.
