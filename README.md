# Platform-SSO-Okta-Password-Status

# Okta Password Status for macOS

> Retrieve Okta password expiry data via the Users API and surface it to end users through the [Root3 Support App](https://github.com/root3nl/SupportApp) and Jamf Pro Extension Attributes.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Okta API Setup](#okta-api-setup)
- [Plist Schema](#plist-schema)
- [Scripts](#scripts)
  - [Script 1 — Okta Password Status](#script-1--okta-password-status)
  - [Script 2 — Support App Extension](#script-2--support-app-extension)
- [Jamf Pro Extension Attributes](#jamf-pro-extension-attributes)
- [Jamf Pro Deployment](#jamf-pro-deployment)
- [Local Testing](#local-testing)
- [Troubleshooting](#troubleshooting)
- [Security Considerations](#security-considerations)
- [Changelog](#changelog)

---

## Overview

Okta does not natively push password expiry notifications to macOS endpoints. This project solves that gap with a two-script approach:

1. **Script 1** runs daily via Jamf Pro, queries the Okta Users API for the logged-in user's password status, and persists the result to a local plist.
2. **Script 2** is a Support App extension that reads the plist and displays password age, days remaining, and expiry warnings directly in the menu bar.

Additionally, Jamf Pro Extension Attributes read the same plist, enabling Smart Groups for compliance reporting and automated remediation (e.g. notification policies when passwords approach expiry).

---

## Architecture

┌───────────────────────────────────────────────────────────────────────┐
│                        Jamf Pro Policy                                 │
│         Trigger: login + Recurring Check-in (once per day)            │
│         Script: zilch_okta_password_status.zsh                        │
│         Parameters: $4=SSWS Token, $5=Domain, $6=Max Age             │
└───────────────────────────────┬───────────────────────────────────────┘
│
▼
┌───────────────────────────────────────────────────────────────────────┐
│                     Okta Users API                                     │
│         GET /api/v1/users/{upn}                                       │
│         Returns: status, passwordChanged, lastLogin, credentials      │
└───────────────────────────────┬───────────────────────────────────────┘
│
▼
┌───────────────────────────────────────────────────────────────────────┐
│              Local Plist (system-level, root-owned)                    │
│    /Library/Application Support/Zilch/com.zilch.passwordstatus.plist  │
│                                                                       │
│    ├── PasswordLastChanged    "2026-04-01T11:22:33Z"                  │
│    ├── PasswordAge            "42"                                     │
│    ├── PasswordDaysRemaining  "48"                                     │
│    ├── PasswordExpired        "false"                                  │
│    ├── PasswordMaxAgeDays     "90"                                     │
│    ├── UserStatus             "ACTIVE"                                 │
│    ├── CredentialProvider     "OKTA"                                   │
│    ├── OktaUPN                "first.last@zilch.technology"            │
│    ├── LastLogin              "2026-05-12T08:30:00Z"                   │
│    └── LastChecked            "2026-05-13T09:00:00Z"                   │
└──────────────┬────────────────────────────────────┬───────────────────┘
│                                    │
▼                                    ▼
┌──────────────────────────────┐   ┌────────────────────────────────────┐
│   Support App Extension       │   │   Jamf Pro Extension Attributes    │
│   Reads plist → menu bar      │   │   Reads plist → inventory          │
│   Warns at ≤14 days           │   │   Enables Smart Groups             │
└──────────────────────────────┘   └────────────────────────────────────┘

markdown

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| **macOS** | Sequoia 15.x / Tahoe 26.x (Apple Silicon) |
| **Jamf Pro** | Managed endpoints with recurring check-in |
| **Okta** | Okta Identity Engine (OIE) tenant |
| **jq** | Deployed via Jamf policy (`install_jq` trigger) |
| **Support App** | [Root3 Support App](https://github.com/root3nl/SupportApp) v2.5+ |
| **Platform SSO** | Okta Platform SSO registered (preferred for UPN resolution) |

---

## Okta API Setup

### Create an SSWS API Token

1. Log in to your Okta Admin Console (e.g. `payzilch.okta.com/admin`)
2. Navigate to **Security → API → Tokens**
3. Click **Create Token**
4. Name: `Jamf-PasswordStatus-ReadOnly`
5. Copy the token immediately (shown only once)

> **Best practice:** Create the token under a dedicated service account with read-only admin privileges. The token inherits the permissions of the creating administrator.

### Required Permissions

The SSWS token needs the ability to call:

GET /api/v1/users/{login}

xml

A **Read-Only Administrator** role is sufficient. No write access is required.

### Alternative: OAuth 2.0 (API Services App)

If your organisation requires scoped OAuth tokens instead of SSWS:

1. **Applications → Applications → Create App Integration → API Services**
2. **Okta API Scopes** tab → Grant `okta.users.read`
3. **Important:** Disable DPoP if enabled (General → Client Credentials → Proof of Possession → None)
4. Modify Script 1 to exchange `client_id` + `client_secret` for a bearer token before API calls

> For fleet scripting use cases, SSWS is recommended due to simplicity. DPoP adds significant complexity unsuitable for shell scripts.

---

## Plist Schema

**Path:** `/Library/Application Support/Zilch/com.zilch.passwordstatus.plist`  
**Owner:** `root:wheel`  
**Permissions:** `644`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PasswordLastChanged</key>
    <string>2026-04-01T11:22:33Z</string>
    <key>PasswordAge</key>
    <string>42</string>
    <key>PasswordDaysRemaining</key>
    <string>48</string>
    <key>PasswordExpired</key>
    <string>false</string>
    <key>PasswordMaxAgeDays</key>
    <string>90</string>
    <key>UserStatus</key>
    <string>ACTIVE</string>
    <key>CredentialProvider</key>
    <string>OKTA</string>
    <key>OktaUPN</key>
    <string>mario.alletto@zilch.technology</string>
    <key>LastLogin</key>
    <string>2026-05-12T08:30:00Z</string>
    <key>LastChecked</key>
    <string>2026-05-13T09:00:00Z</string>
</dict>
</plist>
Key	Type	Description
PasswordLastChanged	string	ISO 8601 timestamp of last password change
PasswordAge	string	Number of days since last password change
PasswordDaysRemaining	string	Days until password expires (or "N/A" if no expiry policy)
PasswordExpired	string	true / false
PasswordMaxAgeDays	string	Maximum password age from policy
UserStatus	string	Okta user status (ACTIVE, LOCKED_OUT, PASSWORD_EXPIRED, etc.)
CredentialProvider	string	Credential source (OKTA, ACTIVE_DIRECTORY, LDAP)
OktaUPN	string	Resolved User Principal Name
LastLogin	string	Last Okta login timestamp
LastChecked	string	When this script last ran successfully
Scripts
Script 1 — Okta Password Status
File: scripts/zilch_okta_password_status.zsh

Purpose: Query Okta API for password data and persist to local plist.

UPN Resolution Priority:

app-sso -l (Platform SSO login name)
dscl . read AltSecurityIdentities (PlatformSSO entry)
Okta Verify UserContext.plist
Fallback: {shortname}@zilch.technology
Fallback behaviour: If the Okta API returns no passwordChanged date (e.g. federated user, newly provisioned account), the script falls back to the local macOS passwordLastSetTime from Directory Services.

Jamf Pro inventory update: Triggered automatically when the password date changes between runs.

Script 2 — Support App Extension
File: scripts/supportapp_password_extension.zsh

Purpose: Read the plist and display password status in the Support App menu bar widget.

Display behaviour:

Condition	Display	Alert
> 14 days remaining	Changed: 01/04/2026	❌
48 Days Left	
≤ 14 days remaining	Changed: 01/04/2026	⚠️ Orange
⚠️ 7 Days Left	
Expired	⚠️ PASSWORD EXPIRED	⚠️ Orange
Changed: 01/04/2026	
No data	No data available	⚠️ Orange
Run password check policy	
Support App configuration (managed preferences or JSON):

json
{
    "Extensions": [
        {
            "Title": "Password Age",
            "Type": "Script",
            "Script": "/Library/Application Support/Zilch/supportapp_password_extension.zsh",
            "Symbol": "key.fill"
        }
    ]
}
Jamf Pro Extension Attributes
Password Age (Days)
File: extension-attributes/ea_password_age.zsh

zsh
#!/bin/zsh
PLIST="/Library/Application Support/Zilch/com.zilch.passwordstatus.plist"
if [[ -f "$PLIST" ]]; then
    result=$$(/usr/libexec/PlistBuddy -c "print :PasswordAge" "$$PLIST" 2>/dev/null)
    [[ -z "$result" ]] && result="Unknown"
else
    result="Not Available"
fi
echo "<result>${result}</result>"
Password Expiry Status
File: extension-attributes/ea_password_expiry_status.zsh

zsh
#!/bin/zsh
PLIST="/Library/Application Support/Zilch/com.zilch.passwordstatus.plist"
if [[ -f "$PLIST" ]]; then
    expired=$$(/usr/libexec/PlistBuddy -c "print :PasswordExpired" "$$PLIST" 2>/dev/null)
    remaining=$$(/usr/libexec/PlistBuddy -c "print :PasswordDaysRemaining" "$$PLIST" 2>/dev/null)
    status=$$(/usr/libexec/PlistBuddy -c "print :UserStatus" "$$PLIST" 2>/dev/null)
    result="$${status} | Expired: $${expired} | Days Remaining: ${remaining}"
else
    result="Not Available"
fi
echo "<result>${result}</result>"
Suggested Smart Groups
Smart Group	Criteria	Use Case
Password Expiring Soon	EA "Password Age" ≥ 76	Trigger notification policy
Password Expired	EA "Password Expiry Status" contains "Expired: true"	Compliance reporting
Password Status Missing	EA "Password Age" = "Not Available"	Scoping for initial deployment
Jamf Pro Deployment
Policy Configuration — Script 1
Setting	Value
Display Name	Zilch — Okta Password Status
Trigger	Login, Recurring Check-in
Execution Frequency	Once per day
Script	zilch_okta_password_status.zsh
Parameter 4 (Label: SSWS Token)	00abc123...
Parameter 5 (Label: Okta Domain)	payzilch.okta.com
Parameter 6 (Label: Max Age Days)	90
Scope	All Managed Clients
Support App Extension — Script 2
Deploy supportapp_password_extension.zsh to:

bash
/Library/Application Support/Zilch/supportapp_password_extension.zsh
Ensure it's executable:

bash
chmod +x "/Library/Application Support/Zilch/supportapp_password_extension.zsh"
Reference it in your Support App configuration profile (managed preferences or JSON).

Local Testing
A standalone test script is included for development/validation without Jamf Pro:

File: scripts/test_okta_password_local.zsh

bash
# Edit the three variables at the top of the script:
#   OKTA_API_TOKEN="your_ssws_token"
#   OKTA_DOMAIN="payzilch.oktapreview.com"
#   TEST_UPN="mario.alletto@payzilch.dev"

chmod +x scripts/test_okta_password_local.zsh
./scripts/test_okta_password_local.zsh
Expected output:

yaml
--- Calling Okta Users API ---
HTTP Status: 200

--- Raw Response (trimmed) ---
{
  "status": "ACTIVE",
  "passwordChanged": "2026-04-01T11:22:33.000Z",
  "credentials": {
    "provider": {
      "type": "OKTA",
      "name": "OKTA"
    }
  }
}

===========================================
  SUMMARY
===========================================
  UPN:                mario.alletto@payzilch.dev
  User Status:        ACTIVE
  Credential Provider:OKTA
  Password Changed:   2026-04-01T11:22:33.000Z
  Password Age:       42 days
  Max Age Policy:     90 days
  Days Remaining:     48
  Expired:            false
  Last Login:         2026-05-12T08:30:00.000Z
===========================================
Troubleshooting
Symptom	Likely Cause	Resolution
invalid_client	Client secret contains $ or special characters not escaped	Use single quotes around secret; use --data-urlencode
invalid_dpop_proof	DPoP enforced on API Services app	Disable DPoP (App → General → Proof of Possession → None) or use SSWS token instead
HTTP 401	Expired or revoked SSWS token	Regenerate token in Security → API → Tokens
HTTP 404	UPN doesn't match an Okta user	Check UPN resolution; verify user exists in Okta
jq: command not found	jq not installed	Ensure install_jq policy trigger is configured
Plist empty / missing	Script hasn't run yet	Trigger the policy manually: sudo jamf policy -trigger login
Support App shows "No data available"	Plist doesn't exist or is unreadable	Check permissions: ls -la /Library/Application\ Support/Zilch/
Password age shows 0	Date parsing failed	Check OKTA_PASSWORD_CHANGED format in /var/log/zilch_password_status.log
Log File
bash
tail -f /var/log/zilch_password_status.log
Security Considerations
Concern	Mitigation
SSWS token in Jamf parameter	Token is only transmitted to the endpoint within the policy payload (encrypted in transit). Consider limiting the token's admin to read-only scope.
Plist readable by all users	File is 644 (world-readable) by design — it contains no secrets, only status metadata.
Token rotation	Set a calendar reminder to rotate the SSWS token quarterly. Update Jamf parameter 4 when rotated.
API rate limiting	Okta rate-limits /api/v1/users at 600 requests/min. With daily per-device execution, this is not a concern for typical fleet sizes.
Network dependency	If Okta is unreachable, the script exits without modifying the plist. Stale data persists until the next successful run.
Repository Structure
r
okta-password-status/
├── README.md
├── scripts/
│   ├── zilch_okta_password_status.zsh        # Script 1 — Jamf policy
│   ├── supportapp_password_extension.zsh     # Script 2 — Support App
│   └── test_okta_password_local.zsh          # Local testing (no Jamf)
├── extension-attributes/
│   ├── ea_password_age.zsh
│   └── ea_password_expiry_status.zsh
├── profiles/
│   └── com.zilch.supportapp.mobileconfig     # Support App config (optional)
└── docs/
    └── screenshots/                          # Support App UI examples
Changelog
1.0.0 — 2026-05-13
Initial release
Okta Users API integration (SSWS authentication)
UPN resolution via Platform SSO, AltSecurityIdentities, Okta Verify, fallback construction
Local password age fallback (Directory Services)
Support App extension with 14-day warning threshold
Jamf Pro Extension Attributes for Smart Group targeting
Automatic inventory update on password date change
Credits
Inspired by Scott Kendall's Entra ID password status script for Giant Eagle
Built for Zilch Platform Engineering
Root3 Support App
Okta Users API Documentation
Licence
Internal use — Zilch Technology Ltd.
