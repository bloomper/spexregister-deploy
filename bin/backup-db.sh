#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
umask 077

keep_days=${BACKUP_KEEP_DAYS:-14}
target=backups/$(date +%Y-%m-%dT%H%M%S)
mkdir -p "$target"

dump() {
  local service=$1 secret=$2
  docker compose exec -T "$service" sh -c \
    "MYSQL_PWD=\$(cat /run/secrets/$secret) exec mysqldump -uroot --single-transaction --routines --triggers --events --default-character-set=utf8mb4 \"\$MYSQL_DATABASE\"" \
    | gzip > "$target/$service.sql.gz"
  echo "wrote $target/$service.sql.gz"
}

dump spexregister-mysql MYSQL_ROOT_PASSWORD

find backups -mindepth 1 -maxdepth 1 -type d -mtime "+$keep_days" -exec rm -rf {} +
