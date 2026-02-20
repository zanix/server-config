#!/bin/env bash
# Creates postgres database dumps and performs a rdiff-backup.
# See /etc/cron.d/backup

DEST="${1:-/backup/postgres}"
KEEP="${2:-30D}"
EXCLUDE_SCHEMAS="'postgres','template0','template1'"
SCHEMA_STMT="SELECT datname from pg_database WHERE datname NOT IN (${EXCLUDE_SCHEMAS})"

# Create directories
mkdir -p "${DEST}"/{dump,rdiff}

# Set directory permissions
chown 109 "${DEST}"/dump
chmod 700 "${DEST}"/dump
chown -R postgres: "${DEST}"/dump

# Clear directory
rm "${DEST}"/dump/*.sql.gz

# Dump databases
for DB in $(su - postgres -s /bin/bash -c "psql -q -t -c \"${SCHEMA_STMT}\"")
do
  su - postgres -s /bin/bash -c "set -o pipefail ; pg_dump ${DB} | gzip --rsyncable > '${DEST}/dump/${DB}.sql.gz'"
done

# RDiff databases
rdiff-backup --api-version 201 backup "${DEST}/dump/" "${DEST}/rdiff/"
rdiff-backup --api-version 201 --force remove increments --older-than "${KEEP}" "${DEST}/rdiff/"
