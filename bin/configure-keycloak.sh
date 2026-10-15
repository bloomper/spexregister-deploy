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

kcadm update "clients/$(client_uuid "$APP_KEYCLOAK_ADMIN_CLIENT_ID")" -r "$APP_KEYCLOAK_REALM" \
  -s 'redirectUris=[]' \
  -s 'webOrigins=[]' \
  -s "frontchannelLogout=false"

web_name=${WEB_NAME:-Spexregister}
web_url="https://$WEB_HOST"
kcadm update "clients/$(client_uuid "$APP_KEYCLOAK_CLIENT_CLIENT_ID")" -r "$APP_KEYCLOAK_REALM" \
  -s "publicClient=false" \
  -s "secret=$(cat secrets/APP_KEYCLOAK_CLIENT_CLIENT_SECRET)" \
  -s "name=$web_name" \
  -s "rootUrl=$web_url" \
  -s "baseUrl=$web_url/" \
  -s "redirectUris=[\"$web_url/api/auth/callback/keycloak\"]" \
  -s 'webOrigins=[]' \
  -s "directAccessGrantsEnabled=false" \
  -s 'attributes."pkce.code.challenge.method"=S256' \
  -s "attributes.\"post.logout.redirect.uris\"=$web_url##$web_url/"
echo "updated $APP_KEYCLOAK_CLIENT_CLIENT_ID secret, name and URLs ($web_name, $web_url)"

mcp_client_id=${APP_KEYCLOAK_MCP_CLIENT_ID:-spexregister-mcp}
mcp_client_uuid=$(client_uuid "$mcp_client_id")
mcp_url="https://$API_HOST/api/mcp"
kcadm update "clients/$mcp_client_uuid" -r "$APP_KEYCLOAK_REALM" \
  -s "directAccessGrantsEnabled=false" \
  -s "consentRequired=true"
mcp_audience=(
  -s "name=mcp audience"
  -s "protocol=openid-connect"
  -s "protocolMapper=oidc-audience-mapper"
  -s "config.\"included.custom.audience\"=$mcp_url"
  -s 'config."access.token.claim"=true'
  -s 'config."id.token.claim"=false'
  -s 'config."introspection.token.claim"=true'
)
mcp_audience_id=$(kcadm get "clients/$mcp_client_uuid/protocol-mappers/models" -r "$APP_KEYCLOAK_REALM" --fields id,name --format csv --noquotes \
  | tr -d '\r' | awk -F, '$2 == "mcp audience" { print $1 }')
if [[ -n "$mcp_audience_id" ]]; then
  kcadm update "clients/$mcp_client_uuid/protocol-mappers/models/$mcp_audience_id" -r "$APP_KEYCLOAK_REALM" "${mcp_audience[@]}"
else
  kcadm create "clients/$mcp_client_uuid/protocol-mappers/models" -r "$APP_KEYCLOAK_REALM" "${mcp_audience[@]}"
fi
echo "disabled direct access grants, required consent and set the audience $mcp_url for $mcp_client_id"

kcadm update "realms/$APP_KEYCLOAK_REALM" \
  -s "bruteForceProtected=true" \
  -s "failureFactor=10" \
  -s "passwordPolicy=length(12) and maxLength(128) and notUsername and notEmail" \
  -s "offlineSessionMaxLifespanEnabled=true" \
  -s "eventsEnabled=true" \
  -s "eventsExpiration=2592000" \
  -s "adminEventsEnabled=true" \
  -s "webAuthnPolicyRpEntityName=FGV" \
  -s 'webAuthnPolicySignatureAlgorithms=["ES256","RS256"]' \
  -s "webAuthnPolicyPasswordlessRpEntityName=FGV" \
  -s 'webAuthnPolicyPasswordlessSignatureAlgorithms=["ES256","RS256"]' \
  -s "webAuthnPolicyPasswordlessResidentKey=required" \
  -s "webAuthnPolicyPasswordlessUserVerificationRequirement=required" \
  -s "webAuthnPolicyPasswordlessPasskeysEnabled=true" \
  -s "browserSecurityHeaders.contentSecurityPolicy=frame-src 'self' https://challenges.cloudflare.com; frame-ancestors 'self'; object-src 'none';"
echo "updated brute force protection, password policy, events, passkeys and content security policy"

if ! kcadm get authentication/flows -r "$APP_KEYCLOAK_REALM" --fields alias --format csv --noquotes | tr -d '\r' | grep -qx "fgv registration"; then
  kcadm create authentication/flows/registration/copy -r "$APP_KEYCLOAK_REALM" -s "newName=fgv registration"
fi
registration_form="authentication/flows/fgv%20registration%20registration%20form/executions"
if ! kcadm get "$registration_form" -r "$APP_KEYCLOAK_REALM" --fields providerId --format csv --noquotes | tr -d '\r' | grep -qx fgv-turnstile; then
  kcadm create "$registration_form/execution" -r "$APP_KEYCLOAK_REALM" -s provider=fgv-turnstile
fi
turnstile_id=$(kcadm get "$registration_form" -r "$APP_KEYCLOAK_REALM" --fields id,providerId --format csv --noquotes \
  | tr -d '\r' | awk -F, '$2 == "fgv-turnstile" { print $1 }')
kcadm update "$registration_form" -r "$APP_KEYCLOAK_REALM" -b "{\"id\":\"$turnstile_id\",\"requirement\":\"REQUIRED\"}"
kcadm update "realms/$APP_KEYCLOAK_REALM" -s "registrationFlow=fgv registration"
kcadm create "realms/$APP_KEYCLOAK_REALM/localization/sv" -r "$APP_KEYCLOAK_REALM" \
  -b '{"recaptchaFailed":"Kontrollen av att du inte är en robot misslyckades. Försök igen."}'
kcadm create "realms/$APP_KEYCLOAK_REALM/localization/en" -r "$APP_KEYCLOAK_REALM" \
  -b '{"recaptchaFailed":"Could not verify that you are not a robot. Please try again."}'
echo "required Turnstile on registration"

realm_id=$(kcadm get "realms/$APP_KEYCLOAK_REALM" --fields id --format csv --noquotes | tr -d '\r')
for key_id in 6c54a31f-cd31-42e6-bf31-158910727a13 449b9119-91fb-4455-b9b2-e7bf4d21b819 \
  8fce98a1-b733-4a35-a815-acd37d296b8b f1a103e8-bc43-4368-81ed-6bc3bcb327a7; do
  provider=$(kcadm get "components/$key_id" -r "$APP_KEYCLOAK_REALM" --fields providerId --format csv --noquotes 2>/dev/null | tr -d '\r') || continue
  kcadm create components -r "$APP_KEYCLOAK_REALM" \
    -s "name=$provider" \
    -s "providerId=$provider" \
    -s "providerType=org.keycloak.keys.KeyProvider" \
    -s "parentId=$realm_id" \
    -s 'config.priority=["200"]'
  kcadm delete "components/$key_id" -r "$APP_KEYCLOAK_REALM"
  echo "replaced the published $provider key"
done

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
