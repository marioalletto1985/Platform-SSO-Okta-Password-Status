#!/bin/zsh
# Extension Attribute: Okta Password Expiry Status
PLIST="/Library/Application Support/Zilch/com.zilch.passwordstatus.plist"
if [[ -f "$PLIST" ]]; then
    expired=$(/usr/libexec/PlistBuddy -c "print :PasswordExpired" "$PLIST" 2>/dev/null)
    days_remaining=$(/usr/libexec/PlistBuddy -c "print :PasswordDaysRemaining" "$PLIST" 2>/dev/null)
    status=$(/usr/libexec/PlistBuddy -c "print :UserStatus" "$PLIST" 2>/dev/null)
    result="${status} | Expired: ${expired} | Days Remaining: ${days_remaining}"
else
    result="Not Available"
fi
echo "<result>${result}</result>"
