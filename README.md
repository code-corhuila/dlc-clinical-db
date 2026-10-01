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
`PLATFORM_NETWORK_NAME` are the only variables this repository reads.
Authentication is intentionally absent from this contract because the
infrastructure credential interface has not been specified here.

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
deploy/  Liquibase migrator only
tooling/ verification used by CI and local development
```

Applied changesets are immutable. Model changes require a new, documented
changeset; this repository does not define cross-domain writes or direct
cross-domain data access.
