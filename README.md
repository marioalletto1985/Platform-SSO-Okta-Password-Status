1. README.md

# Okta Password Status for macOS

> Retrieve Okta password expiry data via the Users API using OAuth 2.0 `private_key_jwt` authentication. Persist to a local plist for Jamf Pro Extension Attribute reporting and Smart Group targeting.

---

## Overview

Okta does not natively surface password expiry information on macOS endpoints. This project solves that with a two-policy approach:

1. **Keychain Seed Policy** — deploys the signing key to each Mac's System Keychain (runs once per computer)
2. **Password Status Policy** — queries Okta daily, calculates password age/expiry, writes results to a local plist

Jamf Pro Extension Attributes read the plist, enabling Smart Groups for compliance reporting and automated remediation.

---

## Architecture

┌─────────────────────────────────────────────────────────────┐
│  Jamf Policy: Seed Keychain (once per computer)              │
│  Parameter $4 = DER private key (base64)                     │
│  Parameter $5 = Okta Key ID (kid)                            │
└──────────────────────────┬──────────────────────────────────┘
│
▼
┌─────────────────────────────────────────────────────────────┐
│  System Keychain (root-only)                                 │
│  Service: com.yourcompany.okta.passwordstatus                │
│  ├── Account: private-key → base64(PEM)                      │
│  └── Account: key-id → kid                                   │
└──────────────────────────┬──────────────────────────────────┘
│
▼
┌─────────────────────────────────────────────────────────────┐
│  Jamf Policy: Password Status (daily)                        │
│  Parameter $4 = Client ID                                    │
│  Parameter $5 = Okta Domain                                  │
│  Parameter $6 = Password Max Age Days                        │
│                                                              │
│  1. Reads key from Keychain                                  │
│  2. Signs JWT (private_key_jwt)                              │
│  3. Gets OAuth access token                                  │
│  4. Queries GET /api/v1/users/{upn}                          │
│  5. Writes plist                                             │
└──────────────────────────┬──────────────────────────────────┘
│
▼
┌─────────────────────────────────────────────────────────────┐
│  /Library/Application Support/yourorg/                       │
│  com.yourorg.passwordstatus.plist                            │
│                                                              │
│  ├── PasswordLastChanged     2026-04-01T11:22:33Z            │
│  ├── PasswordAgeDays         42                               │
│  ├── PasswordDaysRemaining   48                               │
│  ├── PasswordExpired         false                            │
│  ├── PasswordMaxAgeDays      90                               │
│  ├── UserStatus              ACTIVE                           │
│  ├── CredentialProvider      OKTA                             │
│  ├── OktaUPN                 user@yourorg.com                │
│  ├── LastLogin               2026-05-12T08:30:00Z            │
│  └── LastChecked             2026-05-13T09:00:00Z            │
└──────────────────────────┬──────────────────────────────────┘
│
▼
┌─────────────────────────────────────────────────────────────┐
│  Jamf Pro Extension Attributes                                │
│  → Smart Groups for compliance + notifications               │
└─────────────────────────────────────────────────────────────┘

yaml

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| macOS | 15.0+ (Sequoia / Tahoe) |
| Jamf Pro | Managed endpoints with recurring check-in |
| Okta | OIE tenant with API Services app |
| python3 | Need to be installed on macOS |
| openssl | Pre-installed on macOS |

---

## Okta Configuration

### 1. Create an API Services App

1. **Applications → Applications → Create App Integration**
2. Select **API Services**
3. Name: `Jamf Password Status`
4. Save

### 2. Generate Key Pair (on your admin Mac)

```bash
openssl genrsa -out /tmp/okta_private_key.pem 2048
3. Generate JWK (for Okta registration)
bash
MODULUS_HEX=$(openssl rsa -in /tmp/okta_private_key.pem -modulus -noout 2>/dev/null | cut -d= -f2)
KID=$(uuidgen | tr '[:upper:]' '[:lower:]')

python3 -c "
import base64, json

hex_str = '${MODULUS_HEX}'
n_bytes = bytes.fromhex(hex_str)
n = base64.urlsafe_b64encode(n_bytes).rstrip(b'=').decode()
e = base64.urlsafe_b64encode(b'\x01\x00\x01').rstrip(b'=').decode()

jwk = {
    'kty': 'RSA',
    'use': 'sig',
    'alg': 'RS256',
    'kid': '${KID}',
    'n': n,
    'e': e
}
print(json.dumps(jwk, indent=2))
"
4. Register Public Key in Okta
Applications → Your App → General → Client Credentials → Edit
Set Client authentication to Public key / Private key
Disable DPoP (Proof of Possession → None)
Click Add Key → paste the JWK JSON
Save — note the kid assigned
5. Grant API Scope
Okta API Scopes tab → Grant okta.users.read
6. Generate DER Base64 for Jamf Parameter
bash
openssl rsa -in /tmp/okta_private_key.pem -outform DER 2>/dev/null | base64 | tr -d '\n' | pbcopy
echo "✅ DER base64 copied to clipboard (~1624 chars)"
7. Clean Up
bash
rm -f /tmp/okta_private_key.pem
Jamf Pro Deployment
Policy 1: Seed Keychain
Setting	Value
Name	Yourorg — Seed Okta Keychain
Trigger	Recurring Check-in
Frequency	Once per computer
Script	yourorg_seed_okta_keychain.zsh
Parameter 4	DER base64 private key (from step 6)
Parameter 5	kid from Okta (from step 4)
Policy 2: Password Status
Setting	Value
Name	Yourorg — Okta Password Status
Trigger	Login + Recurring Check-in
Frequency	Once per day
Script	yourorg_okta_password_status.zsh
Parameter 4	Client ID (from Okta app)
Parameter 5	Okta domain (e.g. yourorg.okta.com)
Parameter 6	Password max age days (e.g. 90)
Extension Attributes
Password Age (Days)
Setting	Value
Name	Okta Password Age
Data Type	String
Input Type	Script
Password Days Remaining
Setting	Value
Name	Okta Password Days Remaining
Data Type	String
Input Type	Script
Password Expired
Setting	Value
Name	Okta Password Expired
Data Type	String
Input Type	Script
User Status
Setting	Value
Name	Okta User Status
Data Type	String
Input Type	Script
Smart Groups
Smart Group	Criteria	Purpose
Password Expiring Soon	EA "Okta Password Days Remaining" ≤ 14	Trigger notification policy
Password Expired	EA "Okta Password Expired" = "true"	Compliance reporting
Password Status Missing	EA "Okta Password Age" = "Not Available"	Deployment scoping
Plist Schema
Path: /Library/Application Support/yourorg/com.yourorg.passwordstatus.plist
Owner: root:wheel | Permissions: 644

Key	Type	Description
PasswordLastChanged	string	ISO 8601 timestamp
PasswordAgeDays	integer	Days since last change
PasswordDaysRemaining	string	Days until expiry (or "N/A")
PasswordExpired	bool	true/false
PasswordMaxAgeDays	integer	Policy max age
UserStatus	string	ACTIVE, LOCKED_OUT, etc.
CredentialProvider	string	OKTA, ACTIVE_DIRECTORY, etc.
OktaUPN	string	Resolved User Principal Name
LastLogin	string	Last Okta login timestamp
LastChecked	string	Script last ran
ScriptVersion	string	Script version
UPN Resolution Priority
app-sso -l (Platform SSO login name)
dscl . read AltSecurityIdentities (PlatformSSO entry)
Okta Verify UserContext.plist
Fallback: {shortname}@yourorg.com
Security
Concern	Mitigation
Private key on disk	Never — stored in System Keychain only
Key in script	Never — retrieved at runtime
Who can read Keychain	root only
Key in memory	Process substitution — cleared on script exit
Key rotation	Generate new pair → re-register in Okta → re-run seed policy
Log File
bash
tail -f /var/log/yourorg_password_status.log
Repo Structure
lua
okta-password-status/
├── README.md
├── scripts/
│   ├── yourorg_seed_okta_keychain.zsh
│   └── yourorg_okta_password_status.zsh
└── extension-attributes/
    ├── ea_okta_password_age.zsh
    ├── ea_okta_password_days_remaining.zsh
    ├── ea_okta_password_expired.zsh
    
Changelog
2.0.0 — 2026-05-13
OAuth 2.0 private_key_jwt authentication (no static tokens)
Private key stored in System Keychain (DER format for Jamf parameter limit)
python3 JSON parsing (no jq dependency)
UPN resolution via Platform SSO, AltSecurityIdentities, Okta Verify
Local password age fallback
Automatic Jamf inventory update on password date change
