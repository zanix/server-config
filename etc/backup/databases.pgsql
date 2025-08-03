#!/bin/env bash
# Creates postgres database dumps and performs a rdiff-backup.
# See /etc/cron.d/backup

DEST="${1:-/backup/postgres}"
KEEP="${2:-30D}"
EXCLUSION_LIST="'postgres','template0','template1'"
SQLSTMT="SELECT datname from pg_database WHERE datname NOT IN (${EXCLUSION_LIST})"

# Create directories
mkdir -p ${DEST}/{dump,rdiff}

# Set directory permissions
chown 109 ${DEST}/dump
chmod 700 ${DEST}/dump
chown -R postgres: ${DEST}/dump

# Clear directory
rm ${DEST}/dump/*.sql.gz

# Dump databases
for DB in `su - postgres -s /bin/bash -c "psql -q -t -c \"${SQLSTMT}\""`
do
  su - postgres -s /bin/bash -c "set -o pipefail ; pg_dump ${DB} | gzip --rsyncable > '${DEST}/dump/${DB}.sql.gz'"
done

# RDiff databases
rdiff-backup --api-version 201 backup ${DEST}/dump/ ${DEST}/rdiff/
rdiff-backup --api-version 201 remove increments --older-than ${KEEP} ${DEST}/rdiff/
