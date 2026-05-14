#!/bin/zsh --no-rcs
# shellcheck shell=bash
#
# Okta Password Status
# OAuth 2.0 private_key_jwt | python3 JSON parsing | System Keychain
#
# Version: 2.0.0
# Author: Mario Alletto
#
# Jamf Pro Parameters:
#   $4 = Client ID
#   $5 = Okta Domain (default: yourorg.okta.com)
#   $6 = Password Max Age Days (default: 90)
#
# Keychain (seeded via separate policy):
#   Service: com.yourorg.okta.passwordstatus
#   Account: private-key → base64-encoded PEM
#   Account: key-id → Okta kid
#

readonly SCRIPT_NAME="yourorg Okta Password Status"
readonly SCRIPT_VERSION="2.0.0"
readonly LOG_FILE="/var/log/yourorg_password_status.log"

readonly LOGGED_IN_USER=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }')
readonly LOGGED_IN_UID=$(id -u "$LOGGED_IN_USER" 2>/dev/null)

readonly PLIST_DIR="/Library/Application Support/yourorg"
readonly PLIST_FILE="${PLIST_DIR}/com.yourorg.passwordstatus.plist"

readonly KEYCHAIN_SERVICE="com.yourorg.okta.passwordstatus"
readonly KEYCHAIN_PATH="/Library/Keychains/System.keychain"

OKTA_CLIENT_ID="${4}"
OKTA_DOMAIN="${5:-yourorg.okta.com}"
PASSWORD_MAX_AGE_DAYS="${6:-90}"

###############################################################################
# Logging
###############################################################################

function log_message() {
    local level="$1" message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${level}] ${message}" | tee -a "$LOG_FILE"
}
function log_info()  { log_message "INFO" "$1"; }
function log_warn()  { log_message "WARN" "$1"; }
function log_error() { log_message "ERROR" "$1"; }

###############################################################################
# JSON Helper (python3 — no external dependencies)
###############################################################################

function json_get() {
    local json="$1" key="$2" default="${3:-null}"
    echo "$json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    keys = '${key}'.split('.')
    val = data
    for k in keys:
        if isinstance(val, dict):
            val = val.get(k)
        else:
            val = None
            break
    if val is None:
        print('${default}')
    else:
        print(val)
except:
    print('${default}')
" 2>/dev/null
}

###############################################################################
# Pre-flight
###############################################################################

function check_logged_in_user() {
    if [[ -z "$LOGGED_IN_USER" ]] || [[ "$LOGGED_IN_USER" == "loginwindow" ]]; then
        log_info "No user logged in — exiting"
        exit 0
    fi
    log_info "Logged-in user: ${LOGGED_IN_USER} (UID: ${LOGGED_IN_UID})"
}

function validate_parameters() {
    [[ -z "$OKTA_CLIENT_ID" ]] && { log_error "Parameter 4 (Client ID) required"; exit 1; }
    [[ -z "$OKTA_DOMAIN" ]] && { log_error "Parameter 5 (Okta Domain) required"; exit 1; }
}

function check_prerequisites() {
    command -v python3 &>/dev/null || { log_error "python3 not found"; exit 1; }
    command -v openssl &>/dev/null || { log_error "openssl not found"; exit 1; }
    [[ ! -d "$PLIST_DIR" ]] && { mkdir -p "$PLIST_DIR"; chmod 755 "$PLIST_DIR"; }
}

###############################################################################
# Keychain
###############################################################################

function retrieve_keychain_credentials() {
    PRIVATE_KEY_B64=$(security find-generic-password \
        -s "$KEYCHAIN_SERVICE" -a "private-key" \
        -w "$KEYCHAIN_PATH" 2>/dev/null)

    OKTA_KEY_ID=$(security find-generic-password \
        -s "$KEYCHAIN_SERVICE" -a "key-id" \
        -w "$KEYCHAIN_PATH" 2>/dev/null)

    if [[ -z "$PRIVATE_KEY_B64" ]] || [[ -z "$OKTA_KEY_ID" ]]; then
        log_error "Credentials not found in System Keychain — run seed policy first"
        exit 1
    fi
    log_info "Credentials retrieved from System Keychain"
}

###############################################################################
# OAuth 2.0 — private_key_jwt
###############################################################################

function obtain_access_token() {
    local token_endpoint="https://${OKTA_DOMAIN}/oauth2/v1/token"

    # Build JWT
    local jwt_header=$(printf '{"alg":"RS256","typ":"JWT","kid":"%s"}' "$OKTA_KEY_ID")
    local iat=$(date +%s)
    local exp=$((iat + 300))
    local jti=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local jwt_payload=$(printf '{"iss":"%s","sub":"%s","aud":"%s","iat":%s,"exp":%s,"jti":"%s"}' \
        "$OKTA_CLIENT_ID" "$OKTA_CLIENT_ID" "$token_endpoint" "$iat" "$exp" "$jti")

    local b64_header=$(printf '%s' "$jwt_header" | base64 | tr '+/' '-_' | tr -d '=\n')
    local b64_payload=$(printf '%s' "$jwt_payload" | base64 | tr '+/' '-_' | tr -d '=\n')
    local signing_input="${b64_header}.${b64_payload}"

    # Sign — key decoded in memory via process substitution
    local signature=$(printf '%s' "$signing_input" | \
        openssl dgst -sha256 -sign <(echo "$PRIVATE_KEY_B64" | base64 -d) 2>/dev/null | \
        base64 | tr '+/' '-_' | tr -d '=\n')

    [[ -z "$signature" ]] && { log_error "JWT signing failed"; exit 1; }

    local client_assertion="${signing_input}.${signature}"

    # Token request
    local token_response=$(curl -s -X POST "$token_endpoint" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
        --data-urlencode "client_assertion=${client_assertion}" \
        --data-urlencode "scope=okta.users.read")

    OKTA_ACCESS_TOKEN=$(json_get "$token_response" "access_token" "")

    if [[ -z "$OKTA_ACCESS_TOKEN" ]]; then
        log_error "Token request failed: $(json_get "$token_response" "error_description" "unknown")"
        exit 1
    fi

    log_info "Access token acquired (expires in $(json_get "$token_response" "expires_in" "?")s)"
}

###############################################################################
# UPN Resolution
###############################################################################

function resolve_okta_upn() {
    # Priority 1: Platform SSO
    local psso_login=$(app-sso -l 2>/dev/null | grep -i "Login Name" | head -1 | awk -F': ' '{print $2}' | xargs)
    if [[ -n "$psso_login" ]] && [[ "$psso_login" == *"@"* ]]; then
        OKTA_UPN="$psso_login"
        log_info "UPN via Platform SSO: ${OKTA_UPN}"
        return 0
    fi

    # Priority 2: AltSecurityIdentities
    local alt_id=$(dscl . read /Users/"${LOGGED_IN_USER}" AltSecurityIdentities 2>/dev/null | grep -i "PlatformSSO" | awk -F':' '{print $NF}' | xargs)
    if [[ -n "$alt_id" ]] && [[ "$alt_id" == *"@"* ]]; then
        OKTA_UPN="$alt_id"
        log_info "UPN via AltSecurityIdentities: ${OKTA_UPN}"
        return 0
    fi

    # Priority 3: Okta Verify
    local okta_plist="/Users/${LOGGED_IN_USER}/Library/Application Support/Okta/OktaVerify/UserContext.plist"
    if [[ -f "$okta_plist" ]]; then
        local email=$(/usr/libexec/PlistBuddy -c "print :Email" "$okta_plist" 2>/dev/null)
        if [[ -n "$email" ]] && [[ "$email" == *"@"* ]]; then
            OKTA_UPN="$email"
            log_info "UPN via Okta Verify: ${OKTA_UPN}"
            return 0
        fi
    fi

    # Priority 4: Fallback
    OKTA_UPN="${LOGGED_IN_USER}@yourorg.com"
    log_warn "UPN fallback: ${OKTA_UPN}"
}

###############################################################################
# Okta API
###############################################################################

function okta_get_user() {
    local response=$(curl -s -w "\n%{http_code}" \
        -X GET "https://${OKTA_DOMAIN}/api/v1/users/${OKTA_UPN}" \
        -H "Authorization: Bearer ${OKTA_ACCESS_TOKEN}" \
        -H "Accept: application/json")

    local http_code=$(echo "$response" | tail -1)
    local body=$(echo "$response" | sed '$d')

    if [[ "$http_code" -ne 200 ]]; then
        log_error "Okta API HTTP ${http_code} for ${OKTA_UPN}"
        log_error "$(json_get "$body" "errorSummary" "Unknown error")"
        exit 1
    fi

    OKTA_USER_RESPONSE="$body"
    log_info "User profile retrieved"
}

function parse_password_status() {
    OKTA_USER_STATUS=$(json_get "$OKTA_USER_RESPONSE" "status" "UNKNOWN")
    OKTA_PASSWORD_CHANGED=$(json_get "$OKTA_USER_RESPONSE" "passwordChanged" "null")
    OKTA_LAST_LOGIN=$(json_get "$OKTA_USER_RESPONSE" "lastLogin" "null")
    OKTA_CREDENTIAL_PROVIDER=$(json_get "$OKTA_USER_RESPONSE" "credentials.provider.type" "UNKNOWN")

    log_info "Status: ${OKTA_USER_STATUS} | Changed: ${OKTA_PASSWORD_CHANGED}"
}

###############################################################################
# Date Calculations
###############################################################################

function calculate_password_age() {
    local password_date="$1"

    if [[ -z "$password_date" ]] || [[ "$password_date" == "null" ]]; then
        PASSWORD_AGE_DAYS=0
        log_warn "No password date — using local fallback"
        get_local_password_age
        return
    fi

    local normalised=$(echo "$password_date" | sed 's/\.[0-9]*Z$/Z/')
    local pw_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$normalised" "+%s" 2>/dev/null)

    if [[ -z "$pw_epoch" ]]; then
        PASSWORD_AGE_DAYS=0
        log_warn "Could not parse: ${password_date}"
        return
    fi

    PASSWORD_AGE_DAYS=$(( ($(date +%s) - pw_epoch) / 86400 ))
    log_info "Password age: ${PASSWORD_AGE_DAYS} days"
}

function get_local_password_age() {
    local pw_epoch=$(dscl . read /Users/"${LOGGED_IN_USER}" 2>/dev/null | \
        grep -A1 "passwordLastSetTime" | grep "real" | \
        awk -F'real>|</real' '{print $2}' | awk -F'.' '{print $1}')

    if [[ -n "$pw_epoch" ]]; then
        PASSWORD_AGE_DAYS=$(( ($(date +%s) - pw_epoch) / 86400 ))
        OKTA_PASSWORD_CHANGED=$(date -j -f "%s" "$pw_epoch" "+%Y-%m-%dT%H:%M:%SZ")
        log_info "Local fallback age: ${PASSWORD_AGE_DAYS} days"
    else
        PASSWORD_AGE_DAYS=0
        OKTA_PASSWORD_CHANGED=""
    fi
}

function calculate_expiry() {
    if [[ "${PASSWORD_MAX_AGE_DAYS}" -le 0 ]]; then
        PASSWORD_DAYS_REMAINING="N/A"
        PASSWORD_EXPIRED="false"
        return
    fi

    PASSWORD_DAYS_REMAINING=$(( PASSWORD_MAX_AGE_DAYS - PASSWORD_AGE_DAYS ))
    if [[ "$PASSWORD_DAYS_REMAINING" -le 0 ]]; then
        PASSWORD_EXPIRED="true"
        PASSWORD_DAYS_REMAINING=0
    else
        PASSWORD_EXPIRED="false"
    fi
}

###############################################################################
# Plist
###############################################################################

function write_plist() {
    local force_recon="false"
    local existing_date=$(/usr/libexec/PlistBuddy -c "print :PasswordLastChanged" "$PLIST_FILE" 2>/dev/null)

    if [[ -n "$existing_date" ]] && [[ "$existing_date" != "$OKTA_PASSWORD_CHANGED" ]]; then
        force_recon="true"
    fi

    local keys=(
        "PasswordLastChanged:string:${OKTA_PASSWORD_CHANGED}"
        "PasswordAgeDays:integer:${PASSWORD_AGE_DAYS}"
        "PasswordDaysRemaining:string:${PASSWORD_DAYS_REMAINING}"
        "PasswordExpired:bool:${PASSWORD_EXPIRED}"
        "PasswordMaxAgeDays:integer:${PASSWORD_MAX_AGE_DAYS}"
        "UserStatus:string:${OKTA_USER_STATUS}"
        "CredentialProvider:string:${OKTA_CREDENTIAL_PROVIDER}"
        "OktaUPN:string:${OKTA_UPN}"
        "LastLogin:string:${OKTA_LAST_LOGIN}"
        "LastChecked:string:$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        "ScriptVersion:string:${SCRIPT_VERSION}"
    )

    for entry in "${keys[@]}"; do
        local key=$(echo "$entry" | cut -d: -f1)
        local type=$(echo "$entry" | cut -d: -f2)
        local value=$(echo "$entry" | cut -d: -f3-)

        if ! /usr/libexec/PlistBuddy -c "set :${key} ${value}" "$PLIST_FILE" 2>/dev/null; then
            /usr/libexec/PlistBuddy -c "add :${key} ${type} ${value}" "$PLIST_FILE" 2>/dev/null
        fi
    done

    chmod 644 "$PLIST_FILE"
    log_info "Plist written: ${PLIST_FILE}"

    [[ "$force_recon" == "true" ]] && { log_info "Inventory update triggered"; /usr/local/bin/jamf recon &; }
}

###############################################################################
# Main
###############################################################################

function main() {
    log_info "=========================================="
    log_info "${SCRIPT_NAME} v${SCRIPT_VERSION}"
    log_info "=========================================="

    check_logged_in_user
    validate_parameters
    check_prerequisites
    retrieve_keychain_credentials
    obtain_access_token
    resolve_okta_upn
    okta_get_user
    parse_password_status
    calculate_password_age "$OKTA_PASSWORD_CHANGED"
    calculate_expiry
    write_plist

    log_info "DONE: ${OKTA_UPN} | Age: ${PASSWORD_AGE_DAYS}d | Remaining: ${PASSWORD_DAYS_REMAINING}d | Expired: ${PASSWORD_EXPIRED}"
    exit 0
}

main "$@"
