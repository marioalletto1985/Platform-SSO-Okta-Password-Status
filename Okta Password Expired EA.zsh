#!/bin/zsh
# Extension Attribute: Okta Password Expired EA for Jamf Pro
PLIST="/Library/Application Support/Zilch/com.zilch.passwordstatus.plist"
if [[ -f "$PLIST" ]]; then
    result=$(/usr/libexec/PlistBuddy -c "print :PasswordExpired" "$PLIST" 2>/dev/null)
    [[ -z "$result" ]] && result="Unknown"
else
    result="Not Available"
fi
echo "<result>${result}</result>"
