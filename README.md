# dlc-clinical-db

Clinical's MongoDB migration artifact for Di Lucca. It owns only the logical
`clinical` database: collections, validators, indexes, domain roles and
Liquibase changesets. It does not own or run a MongoDB instance, persistent
volume, database users, or another bounded context's data.

The shared MongoDB instance, its volume, environment values and migration
credentials belong to `dlc-infra-mongo`. This repository contributes only the
`clinical-db-migrate` tooling container on the external `clinical-data` network, the only network on
which `dlc-infra-mongo` publishes MongoDB.

## Deploy by stage

The database is `clinical` in every stage: no database or collection is created per stage. Each stage has its own
MongoDB engine from `dlc-infra-mongo`. What changes per stage is the engine, the secrets, TLS and the Liquibase
context. `dlc-infra-mongo` names the stages after the branches (`develop`, `qa`, `main`); this repository uses
`DLC_ENVIRONMENT` `dev`, `qa` and `prod`. The secret references keep the `dlc-infra-mongo` stage names.

| `DLC_ENVIRONMENT` | Branch | Liquibase context | TLS | Data | Template |
| --- | --- | --- | --- | --- | --- |
| `dev` | `develop` | `dev` | Optional | Synthetic only | `env/.env.dev.example` |
| `qa` | `qa` | `qa` | Required | Synthetic only | `env/.env.qa.example` |
| `prod` | `main` | `prod` | Required | Real | `env/.env.prod.example` |

Order in every stage:

1. `dlc-infra-mongo` starts the engine (`compose.yml`, plus `compose.tls.yml` in qa and prod) and creates
   `clinical_migrator`.
2. This repository migrates as `clinical_migrator` over `clinical-data` (the commands below).
3. `dlc-infra-mongo` creates `clinical_runtime` with the roles that step 2 created
   (`docker compose --profile identities run --rm dlc-mongo-runtime-identity`).
4. `dlc-clinical-api` starts as `clinical_runtime`. It never receives the migrator password, and it refuses to
   start below the required `schema_info` version.

Copy the stage template to `env/.env.<stage>` (ignored by Git), point each `*_FILE` at the materialized secret,
and run:

```bash
# dev
docker compose --env-file env/.env.dev -f deploy/compose.yml -f deploy/compose.auth.yml --profile tooling run --rm clinical-db-migrate
# qa
docker compose --env-file env/.env.qa -f deploy/compose.yml -f deploy/compose.auth.yml -f deploy/compose.tls.yml --profile tooling run --rm clinical-db-migrate
# prod
docker compose --env-file env/.env.prod -f deploy/compose.yml -f deploy/compose.auth.yml -f deploy/compose.tls.yml --profile tooling run --rm clinical-db-migrate
```

`deploy/run-migration.sh` runs inside the migrator and does the following:
- It refuses any `DLC_ENVIRONMENT` other than `dev`, `qa` or `prod`.
- It refuses `qa` and `prod` without the CA, so a migration never runs in clear text there.
- It reads the password from the secret.
- It passes the stage as `--contexts`. Changesets without a context run in every stage; a future synthetic seed must
  declare `context: "dev or qa"`, so it never runs in `prod`.
- With TLS, it imports the stage CA into a truststore that exists only for that run. The Java driver ignores
  `tlsCAFile`, so the CA cannot simply be named in the URL.

Append another Liquibase command to inspect a stage, for example `... run --rm clinical-db-migrate status`. The
container runs as the `liquibase` user (uid 1001), so the materialized secret files must be readable by it.

Not decided yet, and not solved in code:
- Hosting and replica-set size (P-01).
- Backups (P-03) and encryption at rest (P-04).
- The production secret store bindings for the references in the templates.

## Run migrations locally

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
`CLINICAL_DATA_NETWORK_NAME` describe the engine. `PLATFORM_NETWORK_NAME`, the former name of the network
variable, is still accepted.

Without `deploy/compose.auth.yml` the migrator connects anonymously. Only the disposable verification below
accepts that, because the `dlc-infra-mongo` engine always requires authentication: use the stage commands above
against it. Their migration identity is `clinical_migrator` (`dbAdmin`, `readWrite` and `userAdmin` on
`clinical` only).

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

`tooling/test-environment-migration.sh` checks the stage deployment end to end against the real
`dlc-infra-mongo` engine, with test-only secrets and throwaway TLS certificates. For `dev`, `qa` and `prod` it
checks that:
- an unknown stage is refused, and `qa` and `prod` are refused without TLS;
- `clinical_migrator` applies every changeset over `clinical-data`, and a second update applies nothing;
- `clinical_runtime` can read `schema_info` but can neither run DDL nor read `databasechangelog_clinical`;
- a container outside `clinical-data` cannot reach MongoDB, either by name or by IP.

It removes its containers, networks, volumes, image and temporary files. It needs Docker and a checkout of
`dlc-infra-mongo`, which is private, so CI does not run it.

```bash
bash tooling/test-environment-migration.sh ../dlc-infra-mongo            # dev, qa and prod
bash tooling/test-environment-migration.sh ../dlc-infra-mongo qa         # one stage
```

## Structure

```text
01_ddl/  collections, validators, indexes and views
02_dml/  ordered data changes
03_dcl/  password-free Clinical domain roles
changelog/changelog-master.yaml  single entry point
deploy/  Liquibase migrator: compose.auth.yml (stage runner, clinical_migrator), compose.tls.yml (qa, prod),
         run-migration.sh (stage, secret, TLS truststore, contexts)
env/     stage templates without secrets (.env.dev/.qa/.prod.example)
tooling/ verification used by CI and local development, and the stage deployment test
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
