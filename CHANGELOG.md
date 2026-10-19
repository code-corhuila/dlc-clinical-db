# Changelog

All notable changes of `dlc-clinical-db` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the versions follow
[Semantic Versioning](https://semver.org/). Work enters `develop` from `feat/`, `fix/` and `chore/` branches, reaches `qa` through
`promotion/*` branches re-applied with `git cherry-pick -x`, and reaches `main` through a `release/<version>` branch cut from `main`
and filled with the commits of `qa`, also with `git cherry-pick -x`, merged by PR with the approval of @ariel5253. A release is
tagged `v<version>` after the merge. Nothing is merged between permanent branches.

## [Unreleased]

MVP 2: persistence foundation of the Clinical context (MongoDB, logical database `clinical`) for HU-CLN-001
([#5](https://github.com/code-corhuila/dlc-clinical-db/issues/5)), HU-CLN-002
([#6](https://github.com/code-corhuila/dlc-clinical-db/issues/6)), HU-CLN-003
([#7](https://github.com/code-corhuila/dlc-clinical-db/issues/7)) and HU-XCT-001
([#8](https://github.com/code-corhuila/dlc-clinical-db/issues/8)). No release on `main` yet; this section becomes
`[2.0.0] - <merge date>` inside `release/2.0.0`.

### Added

- Ten collections with strict `$jsonSchema` validators (`additionalProperties: false`, `validationLevel: strict`,
  `validationAction: error`): `clinical_records`, `consultations`, `diagnoses`, `clinical_entries`, `treatments`, `procedures`,
  `procedure_extras`, `care_closures`, `inbox_events` and `outbox_events`. An amendment needs both `amendsEntryId` and
  `amendmentReason`. ([#2](https://github.com/code-corhuila/dlc-clinical-db/pull/2))
- Eighteen named indexes: unique business ids (one clinical record per `patientId`); query indexes by record and date, by treatment
  status and by appointment; idempotency (`uq_procedures_completion_idempotency_key`, `uq_procedure_extras_source_record_id`, one
  care closure per procedure); `uq_inbox_events_event_id` for deduplication and `idx_outbox_events_publish_work` for the publisher.
  ([#2](https://github.com/code-corhuila/dlc-clinical-db/pull/2))
- Service roles limited to `clinical`: `clinical_application` (read and write on domain collections, insert only on the outbox),
  `clinical_inbox_consumer` and `clinical_outbox_publisher`. ([#2](https://github.com/code-corhuila/dlc-clinical-db/pull/2))
- Liquibase 4.31.1 with the MongoDB extension, run in the order DDL, DML, DCL from `changelog/changelog-master.yaml`. Changesets
  `clinical-001-create-collections`, `clinical-002-create-indexes` and `clinical-003-create-service-roles`, each with a rollback.
  Separate control collections `databasechangelog_clinical` and `databasechangeloglock_clinical`. No seed data.
  ([#2](https://github.com/code-corhuila/dlc-clinical-db/pull/2), [#4](https://github.com/code-corhuila/dlc-clinical-db/pull/4))
- Replica set `rs0` required. The `clinical-db-migrate` container (Compose profile `tooling`) only runs migrations against an
  external MongoDB on the `platform` network. ([#4](https://github.com/code-corhuila/dlc-clinical-db/pull/4))
- Rebuild check in CI (`tooling/verify-migrations.sh`) on PRs to `develop`, `qa` and `main`, against a temporary `rs0`. It runs
  update twice (the second finds nothing pending), then status, history and validate. It checks the validators, indexes and roles,
  rolls everything back and applies it again. ([#4](https://github.com/code-corhuila/dlc-clinical-db/pull/4))
- `idempotency_keys` collection (`clinical-004`, `clinical-005`, `clinical-007`): strict validator, unique
  `uq_idempotency_keys_scope` (actor, operation, key), TTL index `idx_idempotency_keys_expires_at`; `clinical_application`
  may only `find` and `insert` it (Norma 5.3.8).

### Changed

- The repository no longer runs its own MongoDB or volume; it only owns the migrations of `clinical`. Compatible: no changeset was
  modified. ([#4](https://github.com/code-corhuila/dlc-clinical-db/pull/4))
- `procedure_extras` validator aligned with `clinical-service.yaml` through `clinical-006`: `type` uses
  `ADDITIONAL_MATERIAL` and `description` allows up to 500 characters.
- `diagnoses` validator requires the explicit `consultationId` and accepts `appointmentId` (`clinical-008`), with index
  `idx_diagnoses_consultation_id` (`clinical-009`) (CLN-008).

### Security

- Least-privilege roles limited to the `clinical` database; the application role can only insert into the outbox.
  ([#2](https://github.com/code-corhuila/dlc-clinical-db/pull/2))
- No credentials or data in the repository: `.env.example` lists only connection variables owned by the infrastructure, and secret
  files are ignored. ([#4](https://github.com/code-corhuila/dlc-clinical-db/pull/4))

### Known limits

- `dlc-clinical-api` does not write to these collections or publish the outbox yet.
- The shared MongoDB `rs0`, the `platform` network and the service users depend on `dlc-infra`.
- `01_ddl/03_views` and every `02_dml` folder are still empty.
