#!/usr/bin/env bash
# End-to-end check of the CLI against a LOCAL Cadastre server (never
# production). It signs in with an API key, runs every data command, then
# drives the browser login (PKCE + loopback) and the device login with curl
# standing in for the browser, forces a token refresh and signs out.
#
# Needs: curl, jq, a built CLI (zig build), and a local server with a user who
# has accepted the Terms, an API key, and the CLI's OAuth client
# (bin/rails oauth:cli_client). Set:
#
#   CADASTRE_E2E_BASE_URL   e.g. http://127.0.0.1:3000
#   CADASTRE_E2E_API_KEY    cad_key_... of that user
#   CADASTRE_E2E_CLIENT_ID  the client_id oauth:cli_client printed
#   CADASTRE_E2E_EMAIL, CADASTRE_E2E_PASSWORD  the user's sign-in
#   CADASTRE_E2E_METRO      a CBSA code the server has (default 12420)
#
# Credentials are kept in a temporary file store (CADASTRE_CREDENTIAL_STORE=file
# under a temporary XDG_CONFIG_HOME), so the Keychain is not touched.
set -euo pipefail

: "${CADASTRE_E2E_BASE_URL:?set CADASTRE_E2E_BASE_URL (a local server)}"
: "${CADASTRE_E2E_API_KEY:?}" "${CADASTRE_E2E_CLIENT_ID:?}" "${CADASTRE_E2E_EMAIL:?}" "${CADASTRE_E2E_PASSWORD:?}"
case "$CADASTRE_E2E_BASE_URL" in
  *getcadastre.com*) echo "refusing to run against production" >&2; exit 2 ;;
esac

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLI=${CLI:-$ROOT/zig-out/bin/cadastre}
METRO=${CADASTRE_E2E_METRO:-12420}
B=$CADASTRE_E2E_BASE_URL
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export XDG_CONFIG_HOME=$WORK/config CADASTRE_CREDENTIAL_STORE=file CADASTRE_BASE_URL=$B CADASTRE_CLIENT_ID=$CADASTRE_E2E_CLIENT_ID NO_COLOR=1
unset CADASTRE_API_KEY
CREDS=$XDG_CONFIG_HOME/cadastre/credentials.json
pass=0
step() { printf '%-72s ' "$1"; }
ok() { echo ok; pass=$((pass + 1)); }
die() { echo "FAIL: $*" >&2; exit 1; }

# ---- API key --------------------------------------------------------------------------------
step "whoami before login exits 3"
set +e; "$CLI" whoami >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 3 ] || die "exit $rc"; ok

step "login --key (from stdin)"
printf '%s\n' "$CADASTRE_E2E_API_KEY" | "$CLI" login --key >/dev/null || die "login --key"
[ "$(stat -f %Lp "$CREDS" 2>/dev/null || stat -c %a "$CREDS")" = 600 ] || die "credentials file is not 0600"
ok

step "whoami --json names an api_key"
[ "$("$CLI" whoami --json | jq -r .credential.type)" = api_key ] || die "whoami"; ok

for cmd in "datasets" "measures" "metros" "metro $METRO" "compare $METRO" "screen --min-pop 250k" \
  "rank --min-pop 250k --criterion population:1:higher"; do
  step "$cmd --json carries attribution"
  # shellcheck disable=SC2086
  "$CLI" $cmd --json | jq -e '.attribution | type == "array"' >/dev/null || die "$cmd"
  ok
  step "$cmd prints the attribution"
  # shellcheck disable=SC2086
  "$CLI" $cmd | grep -q '^Attribution' || die "$cmd (human)"
  ok
done

step "an unknown measure is a 422 (exit 1)"
set +e; "$CLI" rank --criterion no_such_measure >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 1 ] || die "exit $rc"; ok

step "logout keeps an API key alive unless --revoke"
"$CLI" logout >/dev/null
curl -fsS -H "Authorization: Bearer $CADASTRE_E2E_API_KEY" "$B/api/v1/me" >/dev/null || die "the key was revoked"
ok

# ---- browser login (PKCE + loopback) ----------------------------------------------------------
J=$WORK/cookies.txt
token_of() { grep -oE "name=\"$1\" value=\"[^\"]+\"" "$2" | head -1 | sed 's/.*value="//;s/"$//'; }
sign_in() {
  curl -s -c "$J" -b "$J" "$B/login" >"$WORK/login.html"
  curl -s -c "$J" -b "$J" -o /dev/null -H 'Sec-Fetch-Site: same-origin' \
    --data-urlencode "authenticity_token=$(token_of authenticity_token "$WORK/login.html")" \
    --data-urlencode "email_address=$CADASTRE_E2E_EMAIL" --data-urlencode "password=$CADASTRE_E2E_PASSWORD" "$B/login"
}
approve() { # $1: the consent page; prints the redirect URL
  local acc
  acc=$(grep -oE 'name="account_id"[^>]*value="[^"]+"|value="[^"]+"[^>]*name="account_id"' "$1" | head -1 | grep -oE 'value="[^"]+"' | sed 's/value="//;s/"$//')
  curl -s -c "$J" -b "$J" -o /dev/null -w '%{redirect_url}' -H 'Sec-Fetch-Site: same-origin' \
    --data-urlencode "authenticity_token=$(token_of authenticity_token "$1")" \
    --data-urlencode "request_token=$(token_of request_token "$1")" \
    --data-urlencode "account_id=$acc" --data-urlencode decision=approve "$B/oauth/authorize"
}

step "browser login: the consent page approves, the CLI gets the code"
"$CLI" login --no-browser >"$WORK/login.out" 2>"$WORK/login.err" &
cli_pid=$!
for _ in $(seq 50); do grep -q 'oauth/authorize?' "$WORK/login.err" 2>/dev/null && break; sleep 0.2; done
AU=$(grep -oE 'http[^ ]*/oauth/authorize\?[^ ]*' "$WORK/login.err" | head -1)
[ -n "$AU" ] || die "no authorization URL printed"
case "$AU" in *code_challenge_method=S256*resource=*) ;; *) die "authorization URL lacks PKCE/resource: $AU" ;; esac
sign_in
curl -s -c "$J" -b "$J" -o "$WORK/consent.html" "$AU"
REDIRECT=$(approve "$WORK/consent.html")
case "$REDIRECT" in http://127.0.0.1:*/callback\?code=*) ;; *) die "unexpected redirect: $REDIRECT" ;; esac
curl -s "$REDIRECT" | grep -q 'Signed in to Cadastre' || die "the loopback page"
wait "$cli_pid" || die "login exited non-zero: $(cat "$WORK/login.err")"
ok

step "the saved sign-in is OAuth and works"
[ "$("$CLI" whoami --json | jq -r .credential.type)" = oauth ] || die "whoami"
"$CLI" metro "$METRO" --json | jq -e .data.cbsa >/dev/null || die "metro"
ok

step "an expired access token is refreshed and rotated"
old_rt=$(jq -r '.credentials[].refresh_token' "$CREDS")
jq '.credentials[].expires_at = 0' "$CREDS" >"$CREDS.new" && mv "$CREDS.new" "$CREDS" && chmod 600 "$CREDS"
"$CLI" whoami >/dev/null || die "whoami after expiry"
new_rt=$(jq -r '.credentials[].refresh_token' "$CREDS")
[ "$old_rt" != "$new_rt" ] || die "the refresh token did not rotate"
ok

step "logout revokes the sign-in"
at=$(jq -r '.credentials[].access_token' "$CREDS")
"$CLI" logout >/dev/null
[ ! -s "$CREDS" ] || [ "$(jq '.credentials | length' "$CREDS")" = 0 ] || die "credential left behind"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $at" "$B/api/v1/me")
[ "$code" = 401 ] || die "the access token still works ($code)"
ok

# ---- device login ---------------------------------------------------------------------------
step "device login: the code typed at /oauth/device signs in"
"$CLI" login --device >"$WORK/device.out" 2>"$WORK/device.err" &
cli_pid=$!
for _ in $(seq 50); do grep -qE '^  [B-Z]{4}-[B-Z]{4}$' "$WORK/device.err" 2>/dev/null && break; sleep 0.2; done
UC=$(grep -oE '^  [B-Z]{4}-[B-Z]{4}$' "$WORK/device.err" | tr -d ' ')
[ -n "$UC" ] || die "no user code printed: $(cat "$WORK/device.err")"
curl -s -c "$J" -b "$J" "$B/oauth/device" >"$WORK/device.html"
curl -s -c "$J" -b "$J" -o "$WORK/device-consent.html" -H 'Sec-Fetch-Site: same-origin' \
  --data-urlencode "authenticity_token=$(token_of authenticity_token "$WORK/device.html")" \
  --data-urlencode "user_code=$UC" "$B/oauth/device"
approve "$WORK/device-consent.html" >/dev/null
wait "$cli_pid" || die "device login exited non-zero: $(cat "$WORK/device.err")"
[ "$("$CLI" whoami --json | jq -r .credential.type)" = oauth ] || die "whoami"
"$CLI" logout >/dev/null
ok

echo "$pass checks passed against $B"
