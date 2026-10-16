#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
set -a
. ./.env
set +a

kcadm() { docker compose exec -T auth /opt/keycloak/bin/kcadm.sh "$@"; }
client_uuid() { kcadm get clients -r "$API_AUTH_REALM" -q clientId="$1" --fields id --format csv --noquotes | tr -d '\r'; }

kcadm config credentials \
  --server http://localhost:8080/auth \
  --realm master \
  --user "$AUTH_ADMIN" \
  --password "$(cat secrets/AUTH_ADMIN_PASSWORD)"

kcadm update "clients/$(client_uuid "$API_AUTH_ADMIN_CLIENT_ID")" -r "$API_AUTH_REALM" \
  -s 'redirectUris=[]' \
  -s 'webOrigins=[]' \
  -s "frontchannelLogout=false"
echo "removed redirect URIs and web origins from $API_AUTH_ADMIN_CLIENT_ID"

web_name=${WEB_NAME:-Spexregister}
web_url="https://$WEB_HOST"
kcadm update "clients/$(client_uuid "$API_AUTH_CLIENT_CLIENT_ID")" -r "$API_AUTH_REALM" \
  -s "name=$web_name" \
  -s "rootUrl=$web_url" \
  -s "baseUrl=$web_url/" \
  -s "redirectUris=[\"$web_url/api/auth/callback/keycloak\"]" \
  -s 'webOrigins=[]' \
  -s "directAccessGrantsEnabled=false" \
  -s 'attributes."pkce.code.challenge.method"=S256' \
  -s "attributes.\"post.logout.redirect.uris\"=$web_url##$web_url/"
echo "updated $API_AUTH_CLIENT_CLIENT_ID name, URLs and PKCE ($web_name, $web_url)"

mcp_client_id=${API_AUTH_MCP_CLIENT_ID:-spexregister-mcp}
mcp_client_uuid=$(client_uuid "$mcp_client_id")
mcp_url="https://$API_HOST/api/mcp"
kcadm update "clients/$mcp_client_uuid" -r "$API_AUTH_REALM" -s "consentRequired=true"
mcp_audience=(
  -s "name=mcp audience"
  -s "protocol=openid-connect"
  -s "protocolMapper=oidc-audience-mapper"
  -s "config.\"included.custom.audience\"=$mcp_url"
  -s 'config."access.token.claim"=true'
  -s 'config."id.token.claim"=false'
  -s 'config."introspection.token.claim"=true'
)
mcp_audience_id=$(kcadm get "clients/$mcp_client_uuid/protocol-mappers/models" -r "$API_AUTH_REALM" --fields id,name --format csv --noquotes \
  | tr -d '\r' | awk -F, '$2 == "mcp audience" { print $1 }')
if [[ -n "$mcp_audience_id" ]]; then
  kcadm update "clients/$mcp_client_uuid/protocol-mappers/models/$mcp_audience_id" -r "$API_AUTH_REALM" "${mcp_audience[@]}"
else
  kcadm create "clients/$mcp_client_uuid/protocol-mappers/models" -r "$API_AUTH_REALM" "${mcp_audience[@]}"
fi
echo "required consent and set the audience $mcp_url for $mcp_client_id"

kcadm update "realms/$API_AUTH_REALM" \
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

if ! kcadm get authentication/flows -r "$API_AUTH_REALM" --fields alias --format csv --noquotes | tr -d '\r' | grep -qx "fgv registration"; then
  kcadm create authentication/flows/registration/copy -r "$API_AUTH_REALM" -s "newName=fgv registration"
fi
registration_form="authentication/flows/fgv%20registration%20registration%20form/executions"
if ! kcadm get "$registration_form" -r "$API_AUTH_REALM" --fields providerId --format csv --noquotes | tr -d '\r' | grep -qx fgv-turnstile; then
  kcadm create "$registration_form/execution" -r "$API_AUTH_REALM" -s provider=fgv-turnstile
fi
turnstile_id=$(kcadm get "$registration_form" -r "$API_AUTH_REALM" --fields id,providerId --format csv --noquotes \
  | tr -d '\r' | awk -F, '$2 == "fgv-turnstile" { print $1 }')
kcadm update "$registration_form" -r "$API_AUTH_REALM" -b "{\"id\":\"$turnstile_id\",\"requirement\":\"REQUIRED\"}"
kcadm update "realms/$API_AUTH_REALM" -s "registrationFlow=fgv registration"
kcadm create "realms/$API_AUTH_REALM/localization/sv" -r "$API_AUTH_REALM" \
  -b '{"recaptchaFailed":"Kontrollen av att du inte är en robot misslyckades. Försök igen."}'
kcadm create "realms/$API_AUTH_REALM/localization/en" -r "$API_AUTH_REALM" \
  -b '{"recaptchaFailed":"Could not verify that you are not a robot. Please try again."}'
echo "required Turnstile on registration"

if ! kcadm get authentication/flows -r "$API_AUTH_REALM" --fields alias --format csv --noquotes | tr -d '\r' | grep -qx "fgv browser"; then
  kcadm create authentication/flows/browser/copy -r "$API_AUTH_REALM" -s "newName=fgv browser"
fi
conditional_otp="authentication/flows/fgv%20browser%20Browser%20-%20Conditional%20OTP/executions"
if ! kcadm get "$conditional_otp" -r "$API_AUTH_REALM" --fields providerId --format csv --noquotes | tr -d '\r' | grep -qx conditional-credential; then
  kcadm create "$conditional_otp/execution" -r "$API_AUTH_REALM" -s provider=conditional-credential
  passkey_condition_id=$(kcadm get "$conditional_otp" -r "$API_AUTH_REALM" --fields id,providerId --format csv --noquotes \
    | tr -d '\r' | awk -F, '$2 == "conditional-credential" { print $1 }')
  kcadm update "$conditional_otp" -r "$API_AUTH_REALM" -b "{\"id\":\"$passkey_condition_id\",\"requirement\":\"REQUIRED\"}"
  kcadm create "authentication/executions/$passkey_condition_id/config" -r "$API_AUTH_REALM" \
    -s "alias=browser-conditional-credential" \
    -s "config.credentials=webauthn-passwordless"
  kcadm create "authentication/executions/$passkey_condition_id/raise-priority" -r "$API_AUTH_REALM"
fi
kcadm update "realms/$API_AUTH_REALM" -s "browserFlow=fgv browser"
echo "skipped OTP after signing in with a passkey"

realm_id=$(kcadm get "realms/$API_AUTH_REALM" --fields id --format csv --noquotes | tr -d '\r')
for key_id in 6c54a31f-cd31-42e6-bf31-158910727a13 449b9119-91fb-4455-b9b2-e7bf4d21b819 \
  8fce98a1-b733-4a35-a815-acd37d296b8b f1a103e8-bc43-4368-81ed-6bc3bcb327a7; do
  provider=$(kcadm get "components/$key_id" -r "$API_AUTH_REALM" --fields providerId --format csv --noquotes 2>/dev/null | tr -d '\r') || continue
  kcadm create components -r "$API_AUTH_REALM" \
    -s "name=$provider" \
    -s "providerId=$provider" \
    -s "providerType=org.keycloak.keys.KeyProvider" \
    -s "parentId=$realm_id" \
    -s 'config.priority=["200"]'
  kcadm delete "components/$key_id" -r "$API_AUTH_REALM"
  echo "replaced the published $provider key"
done
