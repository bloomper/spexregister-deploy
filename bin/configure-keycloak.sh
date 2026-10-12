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
  -s "rootUrl=https://$WEB_HOST" \
  -s "baseUrl=/" \
  -s 'redirectUris=["/*"]' \
  -s 'webOrigins=["+"]' \
  -s 'attributes."post.logout.redirect.uris"=+'
echo "updated $APP_KEYCLOAK_CLIENT_CLIENT_ID URLs (https://$WEB_HOST)"

if [[ -n "${KEYCLOAK_THEME:-}" ]]; then
  kcadm update "realms/$APP_KEYCLOAK_REALM" -s "loginTheme=$KEYCLOAK_THEME" -s "accountTheme=$KEYCLOAK_THEME"
  echo "updated login and account theme to $KEYCLOAK_THEME"
fi

sample_users=${SAMPLE_USERS:-}
for user in ${sample_users//,/ }; do
  kcadm set-password -r "$APP_KEYCLOAK_REALM" --username "$user" --new-password "$(cat secrets/SAMPLE_USER_PASSWORD)"
  echo "updated password for $user"
done
