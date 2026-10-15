#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
set -a
. ./.env
set +a

kcadm() { docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"; }
client_uuid() { kcadm get clients -r "$APP_KEYCLOAK_REALM" -q clientId="$1" --fields id --format csv --noquotes | tr -d '\r'; }

kcadm config credentials \
  --server http://localhost:8080/auth \
  --realm master \
  --user "$KEYCLOAK_ADMIN" \
  --password "$(cat secrets/KEYCLOAK_ADMIN_PASSWORD)"

kcadm update "clients/$(client_uuid "$APP_KEYCLOAK_ADMIN_CLIENT_ID")" -r "$APP_KEYCLOAK_REALM" \
  -s "secret=$(cat secrets/APP_KEYCLOAK_ADMIN_CLIENT_SECRET)"
echo "updated $APP_KEYCLOAK_ADMIN_CLIENT_ID secret"

kcadm update "clients/$(client_uuid "$APP_KEYCLOAK_CLIENT_CLIENT_ID")" -r "$APP_KEYCLOAK_REALM" \
  -s "secret=$(cat secrets/APP_KEYCLOAK_CLIENT_CLIENT_SECRET)"
echo "updated $APP_KEYCLOAK_CLIENT_CLIENT_ID secret"

if [[ -n "${KEYCLOAK_THEME:-}" ]]; then
  kcadm update "realms/$APP_KEYCLOAK_REALM" -s "loginTheme=$KEYCLOAK_THEME" -s "accountTheme=$KEYCLOAK_THEME" -s "emailTheme=$KEYCLOAK_THEME"
  echo "updated login, account and email theme to $KEYCLOAK_THEME"
fi

smtp=(
  -s "smtpServer.host=$SMTP_HOST"
  -s "smtpServer.port=$SMTP_PORT"
  -s "smtpServer.from=$MAIL_FROM"
  -s "smtpServer.auth=${SMTP_AUTH:-false}"
  -s "smtpServer.user=${SMTP_USER:-}"
  -s "smtpServer.starttls=${SMTP_STARTTLS:-false}"
  -s "smtpServer.ssl=${SMTP_SSL:-false}"
)
if [[ -s secrets/SMTP_PASSWORD ]]; then
  smtp+=(-s "smtpServer.password=$(cat secrets/SMTP_PASSWORD)")
fi
kcadm update "realms/$APP_KEYCLOAK_REALM" "${smtp[@]}"
echo "updated mail settings ($SMTP_HOST:$SMTP_PORT)"
