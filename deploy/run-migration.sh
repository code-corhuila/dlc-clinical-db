#!/bin/sh
# Clinical migrations for one stage (dev, qa or prod) against the dlc-infra-mongo engine, as clinical_migrator.
# The command is the same everywhere; only the host, the secrets, TLS and the Liquibase contexts change.
set -eu

case "${DLC_ENVIRONMENT:-}" in
  dev|qa|prod) ;;
  *) echo "Set DLC_ENVIRONMENT to dev, qa or prod" >&2; exit 2 ;;
esac

readonly password_file=/run/secrets/clinical_migrator_password
[ -r "$password_file" ] || { echo "Mount the clinical_migrator_password secret" >&2; exit 2; }
LIQUIBASE_COMMAND_PASSWORD=$(cat "$password_file")
export LIQUIBASE_COMMAND_PASSWORD

options="replicaSet=${MONGO_REPLICA_SET:-rs0}&authSource=clinical"
readonly ca_file=/run/secrets/mongo_tls_ca
if [ -r "$ca_file" ]; then
  # The Java driver ignores tlsCAFile: the CA goes into a truststore that lives only for this run.
  store="$(mktemp -d)/truststore.p12"
  store_password=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
  keytool -importcert -noprompt -alias dlc-mongo-ca -file "$ca_file" -keystore "$store" \
    -storetype PKCS12 -storepass "$store_password" >/dev/null
  JAVA_OPTS="${JAVA_OPTS:-} -Djavax.net.ssl.trustStore=$store -Djavax.net.ssl.trustStoreType=PKCS12 -Djavax.net.ssl.trustStorePassword=$store_password"
  export JAVA_OPTS
  options="$options&tls=true"
elif [ "$DLC_ENVIRONMENT" != dev ]; then
  echo "TLS is required in $DLC_ENVIRONMENT: add deploy/compose.tls.yml and MONGO_TLS_CA_FILE" >&2
  exit 2
fi

# Changesets without a context run in every stage; a future synthetic seed declares "dev or qa".
exec liquibase \
  --search-path=/workspace \
  --changelog-file=changelog/changelog-master.yaml \
  --url="mongodb://${MONGO_HOST:-dlc-mongo}:${MONGO_PORT:-27017}/clinical?$options" \
  --username=clinical_migrator \
  --database-changelog-table-name=databasechangelog_clinical \
  --database-changelog-lock-table-name=databasechangeloglock_clinical \
  --contexts="$DLC_ENVIRONMENT" \
  --analytics-enabled=false \
  "$@"
