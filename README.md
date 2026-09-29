# dlc-clinical-db

> Clinical bounded context: database schema, validators, migrations and development seeds.

This repository owns the MongoDB database artifact for **Di Lucca Clinical**. It is the source
for the Clinical schema only; other bounded contexts consume Clinical data through contracts,
never through direct database access.

## Scope

Clinical owns clinical histories, antecedents, allergies, consultations, diagnoses, treatments,
procedures and their evolution. It does not own administrative patient data, appointments,
billing, identity, sessions or cross-domain workflow state.

## Data baseline

- MongoDB 8, with a single-node replica set for local development and transaction support.
- Liquibase with the MongoDB extension for ordered, repeatable migrations.
- JSON Schema validators and named unique indexes are part of every collection definition.
- Seeds contain only non-production development data.

The local database uses `clinical` and the replica set `rs0`. Use the URI declared in
`.env.example`; do not place secrets or real patient data in this repository.

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
