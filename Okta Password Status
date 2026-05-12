#!/bin/zsh --no-rcs
#
# Zilch - Okta Password Status
# Queries Okta Users API and persists password data to local plist.
# Deployed via Jamf Pro — runs at login / recurring check-in (daily).
#
# Version: 1.0.0
# Author: Zilch Platform Engineering
# Created: 2026-05-13
#
# Jamf Pro Parameters:
#   $4 = Okta SSWS API Token
#   $5 = Okta Domain (default: payzilch.okta.com)
#   $6 = Password Max Age Days (default: 90)
#
###############################################################################

###############################################################################
# Variables
###############################################################################

readonly SCRIPT_NAME="Zilch Okta Password Status"
readonly SCRIPT_VERSION="1.0.0"
readonly LOG_FILE="/var/log/zilch_password_status.log"

readonly LOGGED_IN_USER=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }')
readonly LOGGED_IN_UID=$(id -u "$LOGGED_IN_USER" 2>/dev/null)

readonly PLIST_DIR="/Library/Application Support/Zilch"
readonly PLIST_FILE="${PLIST_DIR}/com.zilch.passwordstatus.plist"

readonly JQ_PATH="/usr/local/bin/jq"
readonly JQ_INSTALL_POLICY="install_jq"

###############################################################################
# Jamf Pro Parameters
###############################################################################

OKTA_API_TOKEN="${4}"
OKTA_DOMAIN="${5:-payzilch.okta.com}"
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
# Pre-flight
###############################################################################

function check_prerequisites() {
    if [[ ! -x "$JQ_PATH" ]]; then
        log_info "jq not found — triggering install policy"
        /usr/local/bin/jamf policy -trigger "${JQ_INSTALL_POLICY}"
        [[ ! -x "$JQ_PATH" ]] && { log_error "jq install failed"; exit 1; }
    fi
    [[ ! -d "$PLIST_DIR" ]] && { mkdir -p "$PLIST_DIR"; chmod 755 "$PLIST_DIR"; }
}

function check_logged_in_user() {
    if [[ -z "$LOGGED_IN_USER" ]] || [[ "$LOGGED_IN_USER" == "loginwindow" ]]; then
        log_info "No user logged in — exiting"
        exit 0
    fi
    log_info "Logged-in user: ${LOGGED_IN_USER} (UID: ${LOGGED_IN_UID})"
}

function validate_parameters() {
    [[ -z "$OKTA_API_TOKEN" ]] && { log_error "Parameter 4 (SSWS token) required"; exit 1; }
    [[ -z "$OKTA_DOMAIN" ]] && { log_error "Parameter 5 (Okta domain) required"; exit 1; }
}

###############################################################################
# UPN Resolution
###############################################################################

function resolve_okta_upn() {
    # Priority 1: Platform SSO
    local psso_login
    psso_login=$(app-sso -l 2>/dev/null | grep -i "Login Name" | head -1 | awk -F': ' '{print $2}' | xargs)
    if [[ -n "$psso_login" ]] && [[ "$psso_login" == *"@"* ]]; then
        OKTA_UPN="$psso_login"
        log_info "UPN via Platform SSO: ${OKTA_UPN}"
        return 0
    fi

    # Priority 2: AltSecurityIdentities
    local alt_id
    alt_id=$(dscl . read /Users/"${LOGGED_IN_USER}" AltSecurityIdentities 2>/dev/null | grep -i "PlatformSSO" | awk -F':' '{print $NF}' | xargs)
    if [[ -n "$alt_id" ]] && [[ "$alt_id" == *"@"* ]]; then
        OKTA_UPN="$alt_id"
        log_info "UPN via AltSecurityIdentities: ${OKTA_UPN}"
        return 0
    fi

    # Priority 3: Okta Verify
    local okta_plist="/Users/${LOGGED_IN_USER}/Library/Application Support/Okta/OktaVerify/UserContext.plist"
    if [[ -f "$okta_plist" ]]; then
        local email
        email=$(/usr/libexec/PlistBuddy -c "print :Email" "$okta_plist" 2>/dev/null)
        if [[ -n "$email" ]] && [[ "$email" == *"@"* ]]; then
            OKTA_UPN="$email"
            log_info "UPN via Okta Verify: ${OKTA_UPN}"
            return 0
        fi
    fi

    # Priority 4: Fallback
    OKTA_UPN="${LOGGED_IN_USER}@zilch.technology"
    log_warn "UPN fallback (constructed): ${OKTA_UPN}"
}

###############################################################################
# Okta API
###############################################################################

function okta_get_user() {
    local response http_code body

    response=$(curl -s -w "\n%{http_code}" \
        -X GET "https://${OKTA_DOMAIN}/api/v1/users/${OKTA_UPN}" \
        -H "Authorization: SSWS ${OKTA_API_TOKEN}" \
        -H "Accept: application/json")

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" -ne 200 ]]; then
        log_error "Okta API HTTP ${http_code} for ${OKTA_UPN}"
        log_error "Response: ${body}"
        exit 1
    fi

    OKTA_USER_RESPONSE="$body"
    log_info "Okta user profile retrieved successfully"
}

function parse_password_status() {
    OKTA_USER_STATUS=$(echo "$OKTA_USER_RESPONSE" | "$JQ_PATH" -r '.status // "UNKNOWN"')
    OKTA_PASSWORD_CHANGED=$(echo "$OKTA_USER_RESPONSE" | "$JQ_PATH" -r '.passwordChanged // "null"')
    OKTA_LAST_LOGIN=$(echo "$OKTA_USER_RESPONSE" | "$JQ_PATH" -r '.lastLogin // "null"')
    OKTA_CREDENTIAL_PROVIDER=$(echo "$OKTA_USER_RESPONSE" | "$JQ_PATH" -r '.credentials.provider.type // "UNKNOWN"')

    log_info "Status: ${OKTA_USER_STATUS} | Password changed: ${OKTA_PASSWORD_CHANGED}"
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

    local normalised
    normalised=$(echo "$password_date" | sed 's/\.[0-9]*Z$/Z/')
    local pw_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$normalised" "+%s" 2>/dev/null)

    if [[ -z "$pw_epoch" ]]; then
        PASSWORD_AGE_DAYS=0
        log_warn "Could not parse date: ${password_date}"
        return
    fi

    local today_epoch=$(date "+%s")
    PASSWORD_AGE_DAYS=$(( (today_epoch - pw_epoch) / 86400 ))
    log_info "Password age: ${PASSWORD_AGE_DAYS} days"
}

function get_local_password_age() {
    local pw_epoch
    pw_epoch=$(dscl . read /Users/"${LOGGED_IN_USER}" 2>/dev/null | \
        grep -A1 "passwordLastSetTime" | grep "real" | \
        awk -F'real>|</real' '{print $2}' | awk -F'.' '{print $1}')

    if [[ -n "$pw_epoch" ]]; then
        local today_epoch=$(date "+%s")
        PASSWORD_AGE_DAYS=$(( (today_epoch - pw_epoch) / 86400 ))
        OKTA_PASSWORD_CHANGED=$(date -j -f "%s" "$pw_epoch" "+%Y-%m-%dT%H:%M:%SZ")
        log_info "Local password age: ${PASSWORD_AGE_DAYS} days"
    else
        PASSWORD_AGE_DAYS=0
        OKTA_PASSWORD_CHANGED=""
        log_warn "Could not read local password age"
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
# Write Plist
###############################################################################

function write_plist() {
    local force_recon="false"

    # Check for date change
    local existing_date
    existing_date=$(/usr/libexec/PlistBuddy -c "print :PasswordLastChanged" "$PLIST_FILE" 2>/dev/null)
    if [[ -n "$existing_date" ]] && [[ "$existing_date" != "$OKTA_PASSWORD_CHANGED" ]]; then
        force_recon="true"
    fi

    # Write keys
    local keys=(
        "PasswordLastChanged:string:${OKTA_PASSWORD_CHANGED}"
        "PasswordAge:string:${PASSWORD_AGE_DAYS}"
        "PasswordDaysRemaining:string:${PASSWORD_DAYS_REMAINING}"
        "PasswordExpired:string:${PASSWORD_EXPIRED}"
        "PasswordMaxAgeDays:string:${PASSWORD_MAX_AGE_DAYS}"
        "UserStatus:string:${OKTA_USER_STATUS}"
        "CredentialProvider:string:${OKTA_CREDENTIAL_PROVIDER}"
        "OktaUPN:string:${OKTA_UPN}"
        "LastLogin:string:${OKTA_LAST_LOGIN}"
        "LastChecked:string:$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    )

    for entry in "${keys[@]}"; do
        local key type value
        key=$(echo "$entry" | cut -d: -f1)
        type=$(echo "$entry" | cut -d: -f2)
        value=$(echo "$entry" | cut -d: -f3-)

        if ! /usr/libexec/PlistBuddy -c "set :${key} ${value}" "$PLIST_FILE" 2>/dev/null; then
            /usr/libexec/PlistBuddy -c "add :${key} ${type} ${value}" "$PLIST_FILE" 2>/dev/null
        fi
    done

    chmod 644 "$PLIST_FILE"
    log_info "Plist written: ${PLIST_FILE}"

    [[ "$force_recon" == "true" ]] && { log_info "Triggering inventory update"; /usr/local/bin/jamf recon &; }
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
    resolve_okta_upn
    okta_get_user
    parse_password_status
    calculate_password_age "$OKTA_PASSWORD_CHANGED"
    calculate_expiry
    write_plist

    log_info "SUMMARY: ${OKTA_UPN} | Status: ${OKTA_USER_STATUS} | Age: ${PASSWORD_AGE_DAYS}d | Remaining: ${PASSWORD_DAYS_REMAINING}d | Expired: ${PASSWORD_EXPIRED}"
    log_info "Complete"
    exit 0
}

main "$@"
