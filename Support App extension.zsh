#!/bin/zsh --no-rcs
#
# Zilch - Support App Extension: Password Age
# Reads com.zilch.passwordstatus.plist and writes to Root3 Support App preferences.
#
# Version: 1.0.0
# Author: Zilch Platform Engineering
#
# Support App Config:
#   Extension Title: "Password Age"
#   Extension: Script (point to this file)
#
###############################################################################

###############################################################################
# Variables
###############################################################################

readonly EXTENSION_ID="GetPasswordAge"
readonly PLIST_FILE="/Library/Application Support/Zilch/com.zilch.passwordstatus.plist"
readonly SUPPORT_PLIST="/Library/Preferences/nl.root3.support.plist"
readonly PASSWORD_LIMIT=90  # Must match your Okta password policy max age

###############################################################################
# Show Loading State
###############################################################################

defaults write "$SUPPORT_PLIST" "${EXTENSION_ID}_loading" -bool true
sleep 0.5

###############################################################################
# Read Password Data
###############################################################################

if [[ ! -f "$PLIST_FILE" ]]; then
    defaults write "$SUPPORT_PLIST" "${EXTENSION_ID}" -string "No data available\nRun password check policy"
    defaults write "$SUPPORT_PLIST" "${EXTENSION_ID}_loading" -bool false
    defaults write "$SUPPORT_PLIST" "${EXTENSION_ID}_alert" -bool true
    exit 0
fi

# Read values from the Zilch password status plist
PasswordAge=$(/usr/libexec/PlistBuddy -c "print :PasswordAge" "$PLIST_FILE" 2>/dev/null)
PasswordLastChanged=$(/usr/libexec/PlistBuddy -c "print :PasswordLastChanged" "$PLIST_FILE" 2>/dev/null)
UserStatus=$(/usr/libexec/PlistBuddy -c "print :UserStatus" "$PLIST_FILE" 2>/dev/null)

# Validate we got data
if [[ -z "$PasswordAge" ]] || [[ -z "$PasswordLastChanged" ]]; then
    defaults write "$SUPPORT_PLIST" "${EXTENSION_ID}" -string "Unable to read password data"
    defaults write "$SUPPORT_PLIST" "${EXTENSION_ID}_loading" -bool false
    defaults write "$SUPPORT_PLIST" "${EXTENSION_ID}_alert" -bool true
    exit 0
fi

###############################################################################
# Calculate Days Remaining
###############################################################################

daysLeft=$((PASSWORD_LIMIT - PasswordAge))
[[ "$daysLeft" -lt 0 ]] && daysLeft=0

# Format the last changed date for display (ISO → locale short date)
LastChangedDisplay=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$PasswordLastChanged" +"%d/%m/%Y" 2>/dev/null)
[[ -z "$LastChangedDisplay" ]] && LastChangedDisplay="$PasswordLastChanged"

###############################################################################
# Write to Support App
###############################################################################

# Build display string
if [[ "$UserStatus" == "PASSWORD_EXPIRED" ]] || [[ "$daysLeft" -le 0 ]]; then
    displayString="⚠️ PASSWORD EXPIRED\nChanged: ${LastChangedDisplay}"
elif [[ "$daysLeft" -le 14 ]]; then
    displayString="Changed: ${LastChangedDisplay}\n⚠️ ${daysLeft} Days Left"
else
    displayString="Changed: ${LastChangedDisplay}\n${daysLeft} Days Left"
fi

defaults write "$SUPPORT_PLIST" "${EXTENSION_ID}" -string "$displayString"
defaults write "$SUPPORT_PLIST" "${EXTENSION_ID}_loading" -bool false

# Alert threshold: warn at 14 days or fewer
if [[ "$daysLeft" -le 14 ]]; then
    defaults write "$SUPPORT_PLIST" "${EXTENSION_ID}_alert" -bool true
else
    defaults write "$SUPPORT_PLIST" "${EXTENSION_ID}_alert" -bool false
fi

exit 0
