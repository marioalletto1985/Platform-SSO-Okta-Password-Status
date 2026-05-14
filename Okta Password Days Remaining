#!/bin/zsh
# Extension Attribute: Okta Password Days Remaining
PLIST="/Library/Application Support/Yourorg/com.yourorg.passwordstatus.plist"
if [[ -f "$PLIST" ]]; then
    result=$(/usr/libexec/PlistBuddy -c "print :PasswordDaysRemaining" "$PLIST" 2>/dev/null)
    [[ -z "$result" ]] && result="Unknown"
else
    result="Not Available"
fi
echo "<result>${result}</result>"
