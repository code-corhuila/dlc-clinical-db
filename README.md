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
- Liquibase with the MongoDB extension for ordered, forward-only schema changesets.
- JSON Schema validators and named unique indexes are part of every collection definition.
- Seeds contain only non-production development data.

Structural changesets are never edited after deployment. If a migration fails, stop the rollout,
restore from the verified backup or execute the documented compensating changeset, then create a
new forward migration; do not rewrite migration history. The local database uses `clinical` and
the replica set `rs0`; do not place secrets or real patient data in this repository.

## Documentation

The authoritative specifications and governance live in
[`dlc-docs`](https://github.com/code-corhuila/dlc-docs). In particular, follow the Clinical
bounded-context scope, the MongoDB annex and the repository/PR regulations before changing this
artifact.

## Branching

Three permanent branches. **None of them accepts a direct commit** — you enter through a child
branch and leave through a Pull Request.

```
develop  <--PR--  feat/... fix/... chore/...
qa       <--PR--  qa/...
main     <--PR--  release/... hotfix/...
```

Promotion happens **by re-application** (`git cherry-pick -x`), never by merging one permanent
branch into another: `merge develop -> qa` and `merge qa -> main` do not exist in this model.

`main` approval is enforced through the repository's `CODEOWNERS`. Review rules for `develop`
and `qa` are defined by the team according to the course regulation.

Every Pull Request declares the affected user story (or why it is not applicable), stays within
the permitted diff size and targets the correct permanent branch.
