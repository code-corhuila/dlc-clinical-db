# dlc-clinical-db

> Clinical bounded context: database schema, validators, migrations and development seeds.

This repository owns the MongoDB database artifact for **Di Lucca Clinical**. It is the source
for the Clinical schema only; other bounded contexts consume Clinical data through contracts,
never through direct database access.

## Scope

Clinical owns clinical histories, antecedents, allergies, consultations, diagnoses, treatments,
procedures and their evolution. It does not own administrative patient data, appointments,
billing, identity, sessions or cross-domain workflow state.

## Implemented database baseline

- MongoDB 8, with a single-node replica set for local development and transaction support.
- Liquibase with the MongoDB extension for ordered, forward-only schema changesets.
- JSON Schema validators (`strict` / `error`) and named indexes are part of every collection definition.
- The initial migration creates `clinical_records`, `consultations`, `diagnoses`,
  `clinical_entries`, `treatments`, `procedures`, `procedure_extras`,
  `care_closures`, `inbox_events`, and `outbox_events`.
- `clinical_records.patientId`, stable aggregate identifiers, idempotency keys, event IDs,
  extra source records, and care-closure procedure references have explicit unique indexes.
- Clinical documents intentionally contain no money, currency, price, or amount fields.
- `02_dml` is reserved for idempotent, non-production development seeds and future data fixes;
  the baseline deliberately does not insert clinical data.

Structural changesets are never edited after deployment. If a migration fails, stop the rollout,
restore from the verified backup or execute the documented compensating changeset, then create a
new forward migration; do not rewrite migration history. The local database uses `clinical` and
the replica set `rs0`; do not place secrets or real patient data in this repository.

## Local run

Docker Compose starts MongoDB 8 as the one-node `rs0` replica set. Liquibase is built with both
the MongoDB extension and driver required by the project rule.

```powershell
Copy-Item .env.example .env
docker compose -f deploy/compose.yml up -d mongo
docker compose -f deploy/compose.yml --profile migrate run --rm liquibase
```

Run the last command a second time to verify that Liquibase has no pending changesets. The
`deploy/compose.yml` health check initializes the replica set before the migration container
runs. The generated role is `clinical_service`; infrastructure, not this repository, creates
database users, enables authentication and supplies their secrets outside the local Compose setup.

## Layout

```text
01_ddl/  collections, future validator changes, indexes and views
02_dml/  idempotent development seeds and forward data changes
03_dcl/  password-free database roles
changelog/changelog-master.yaml  single Liquibase entry point
deploy/  fixed MongoDB and Liquibase development environment
```

## Documentation

The authoritative specifications and governance live in
[`dlc-docs`](https://github.com/code-corhuila/dlc-docs). In particular, follow the Clinical
bounded-context scope, the MongoDB annex and the repository/PR regulations before changing this
artifact.

## Run migrations

Provide the migration connection contract from `dlc-infra-mongo` (do not commit
it), then run the tooling profile:

```
develop  <--PR--  feat/... fix/... chore/...
qa       <--PR--  qa/...
main     <--PR--  release/... hotfix/...
```

The migrator applies `changelog/changelog-master.yaml` in `01_ddl`, `02_dml`,
then `03_dcl` order. It explicitly stores Clinical migration state in
`databasechangelog_clinical` and `databasechangeloglock_clinical`.

`main` approval is enforced through the repository's `CODEOWNERS`. Review rules for `develop`
and `qa` are defined by the team according to the course regulation.

Every Pull Request declares the affected user story (or why it is not applicable), stays within
the permitted diff size and targets the correct permanent branch.
