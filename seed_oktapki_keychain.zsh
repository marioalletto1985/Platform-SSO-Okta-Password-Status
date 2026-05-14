#!/bin/zsh --no-rcs
#
# Seed Okta Private Key to System Keychain
# Accepts DER-format base64 key (fits Jamf 2000 char parameter limit)
# Run ONCE per computer via Jamf Pro
#
# Parameters:
#   $4 = Base64-encoded private key (DER format)
#   $5 = Okta Key ID (kid)
#
# Version: 2.0.0
# Author: yourorg Platform Engineering
#

readonly KEYCHAIN_SERVICE="com.yourorg.okta.passwordstatus"
readonly KEYCHAIN_PATH="/Library/Keychains/System.keychain"
readonly LOG_FILE="/var/log/yourorg_password_status.log"

DER_KEY_B64="${4}"
KEY_ID="${5}"

function log_info()  { echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1" | tee -a "$LOG_FILE"; }
function log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" | tee -a "$LOG_FILE"; }

# Validate inputs
if [[ -z "$DER_KEY_B64" ]]; then
    log_error "Parameter 4 (DER base64 private key) is required"
    exit 1
fi

if [[ -z "$KEY_ID" ]]; then
    log_error "Parameter 5 (Okta key ID) is required"
    exit 1
fi

# Convert DER to PEM, then base64 encode the full PEM for storage
PEM_KEY_B64=$(echo "$DER_KEY_B64" | base64 -d | \
    openssl rsa -inform DER -outform PEM 2>/dev/null | \
    base64 | tr -d '\n')

if [[ -z "$PEM_KEY_B64" ]]; then
    log_error "Failed to convert DER key to PEM — check parameter 4"
    exit 1
fi

# Remove existing entries (idempotent)
security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "private-key" "$KEYCHAIN_PATH" 2>/dev/null
security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "key-id" "$KEYCHAIN_PATH" 2>/dev/null

# Store PEM (base64) in Keychain
if security add-generic-password \
    -s "$KEYCHAIN_SERVICE" \
    -a "private-key" \
    -w "$PEM_KEY_B64" \
    -T "/usr/bin/security" \
    "$KEYCHAIN_PATH"; then
    log_info "Private key stored in System Keychain"
else
    log_error "Failed to store private key"
    exit 1
fi

# Store key ID
if security add-generic-password \
    -s "$KEYCHAIN_SERVICE" \
    -a "key-id" \
    -w "$KEY_ID" \
    -T "/usr/bin/security" \
    "$KEYCHAIN_PATH"; then
    log_info "Key ID (${KEY_ID}) stored in System Keychain"
else
    log_error "Failed to store key ID"
    exit 1
fi

log_info "Keychain seed complete"
exit 0
