## User story

<!-- code-corhuila/dlc-docs#NN -->

## What changes and why

<!-- Describe the bounded-context change and its motivation. -->

## How it was tested

<!-- List local Docker, MongoDB and Liquibase validation evidence. -->

## Promotion trace

<!-- Required only for qa/main: commits re-applied with cherry-pick -x. -->

## Checklist

- [ ] No secrets or real clinical data are included.
- [ ] The schema change resides only in `dlc-clinical-db`.
- [ ] Validators, indexes, and rollbacks are included where applicable.
- [ ] Contracts and data ownership are preserved.
- [ ] The change does not exceed 400 non-test code lines; it is split when necessary.
