# Okta Password Status for macOS

> Retrieve Okta password expiry data via the Users API using OAuth 2.0 `private_key_jwt` authentication.  
> Persist to a local plist for Jamf Pro Extension Attribute reporting and Smart Group targeting.

[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)]()
[![IdP](https://img.shields.io/badge/IdP-Okta-blue)]()
[![MDM](https://img.shields.io/badge/MDM-Jamf%20Pro-purple)]()
[![Shell](https://img.shields.io/badge/shell-zsh-green)]()
[![Version](https://img.shields.io/badge/version-2.0.0-orange)]()

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Okta Configuration](#okta-configuration)
- [Jamf Pro Deployment](#jamf-pro-deployment)
- [Extension Attributes](#extension-attributes)
- [Smart Groups](#smart-groups)
- [Plist Schema](#plist-schema)
- [UPN Resolution](#upn-resolution)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [Repo Structure](#repo-structure)
- [Changelog](#changelog)

---

## Overview

Okta does not natively surface password expiry information on macOS endpoints. This project solves that gap with a two-policy approach:

1. **Keychain Seed Policy** — deploys the signing key to each Mac's System Keychain (runs once per computer)
2. **Password Status Policy** — queries Okta daily, calculates password age/expiry, and writes results to a local plist

Jamf Pro Extension Attributes read the plist, enabling Smart Groups for compliance reporting and automated remediation.

---

## Architecture

```text
┌──────────────────────────────────────────────────────────────┐
│  Jamf Policy: Seed Keychain (once per computer)               │
│  Parameter \$4 = DER private key (base64)                      │
│  Parameter \$5 = Okta Key ID (kid)                             │
└─────────────────────────────┬────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  System Keychain (root-only)                                  │
│  Service: com.yourcompany.okta.passwordstatus                 │
│  ├── Account: private-key → base64(PEM)                       │
│  └── Account: key-id → kid                                    │
└─────────────────────────────┬────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  Jamf Policy: Password Status (daily)                         │
│  Parameter \$4 = Client ID                                     │
│  Parameter \$5 = Okta Domain                                   │
│  Parameter \$6 = Password Max Age Days                         │
│                                                               │
│  1. Reads key from Keychain                                   │
│  2. Signs JWT (private_key_jwt)                               │
│  3. Gets OAuth access token                                   │
│  4. Queries GET /api/v1/users/{upn}                           │
│  5. Writes plist                                              │
└─────────────────────────────┬────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  /Library/Application Support/yourorg/                         │
│  com.yourorg.passwordstatus.plist                              │
└─────────────────────────────┬────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  Jamf Pro Extension Attributes                                │
│  → Smart Groups for compliance + notifications                │
└──────────────────────────────────────────────────────────────┘

Prerequisites
Requirement	Details
macOS	15.0+ (Sequoia / Tahoe)
Jamf Pro	Managed endpoints with recurring check-in
Okta	OIE tenant with API Services app
python3	Must be installed on macOS
openssl	Pre-installed on macOS

Okta Configuration
Step 1: Create an API Services App
Navigate to Applications → Applications → Create App Integration
Select API Services
Name: Jamf Password Status
Click Save
Step 2: Generate a Key Pair
Run on your admin Mac:

openssl genrsa -out /tmp/okta_private_key.pem 2048

Step 3: Generate the JWK
This converts your public key into a format Okta can accept:

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

Step 4: Register the Public Key in Okta
Go to Applications → Your App → General → Client Credentials → Edit
Set Client authentication to Public key / Private key
Disable DPoP (Proof of Possession → None)
Click Add Key → paste the JWK JSON from Step 3
Click Save — note the kid that Okta assigns

Step 5: Grant API Scope
Go to Okta API Scopes tab
Grant okta.users.read
Step 6: Generate DER Base64 for Jamf
This creates a shorter encoding that fits within Jamf's 2000-character parameter limit:

openssl rsa -in /tmp/okta_private_key.pem -outform DER 2>/dev/null | base64 | tr -d '\n' | pbcopy
echo "✅ DER base64 copied to clipboard (~1624 chars)"

Step 7: Clean Up

rm -f /tmp/okta_private_key.pem

Jamf Pro Deployment
Policy 1: Seed Keychain
Runs once per computer to store the private key securely.

Setting	Value
Name	Seed Okta Keychain Credentials
Trigger	Recurring Check-in
Frequency	Once per computer
Script	yourorg_seed_okta_keychain.zsh
Parameter 4	DER base64 private key (from Step 6)
Parameter 5	kid from Okta (from Step 4)

Policy 2: Password Status
Runs daily to query Okta and update the local plist.

Setting	Value
Name	Okta Password Status
Trigger	Login + Recurring Check-in
Frequency	Once per day
Script	yourorg_okta_password_status.zsh
Parameter 4	Client ID (from Okta app)
Parameter 5	Okta domain (e.g. yourorg.okta.com)
Parameter 6	Password max age days (e.g. 90)

Extension Attributes
All EAs follow the same pattern — read a single key from the plist:

EA Name	Plist Key
Okta Password Age	PasswordAgeDays
Okta Password Days Remaining	PasswordDaysRemaining
Okta Password Expired	PasswordExpired
Okta User Status	UserStatus

Each EA uses Data Type: String and Input Type: Script.

Smart Groups

Smart Group	Criteria	Purpose
Password Expiring Soon	EA "Okta Password Days Remaining" ≤ 14	Trigger notification policy
Password Expired	EA "Okta Password Expired" = "true"	Compliance reporting
Password Status Missing	EA "Okta Password Age" = "Not Available"	Deployment scoping

Plist Schema
Path: /Library/Application Support/yourorg/com.yourorg.passwordstatus.plist

Owner: root:wheel | Permissions: 644

PasswordLastChanged	string	ISO 8601 timestamp of last password change
PasswordAgeDays	integer	Days since last password change
PasswordDaysRemaining	string	Days until expiry (or N/A if no policy)
PasswordExpired	bool	true / false
PasswordMaxAgeDays	integer	Max age from password policy
UserStatus	string	Okta status: ACTIVE, LOCKED_OUT, PASSWORD_EXPIRED, etc.
CredentialProvider	string	OKTA, ACTIVE_DIRECTORY, LDAP, etc.
OktaUPN	string	Resolved User Principal Name
LastLogin	string	Last Okta login timestamp
LastChecked	string	When the script last ran
ScriptVersion	string	Script version number

UPN Resolution
The script resolves the logged-in user's Okta UPN using the following priority:

Priority	Source	Method
1	Platform SSO	app-sso -l
2	Directory Services	dscl . read AltSecurityIdentities (PlatformSSO entry)
3	Okta Verify	UserContext.plist Email field
4	Fallback	{shortname}@yourorg.com

Security
Concern	Mitigation
Private key on disk	❌ Never — stored in System Keychain only
Key in script	❌ Never — retrieved at runtime
Who can read Keychain	root only (System Keychain)
Key in memory	Process substitution — never written, cleared on exit
Key rotation	Generate new pair → re-register in Okta → re-run seed policy
API scope	okta.users.read only — no write access

Troubleshooting
Symptom	Cause	Fix
Credentials not found in System Keychain	Seed policy hasn't run	Trigger seed policy manually
Token request failed	Wrong domain or DPoP enabled	Check parameter 5; disable DPoP in Okta
JWT signing failed	Key mismatch	Re-register JWK in Okta from same PEM
HTTP 404 for user	UPN doesn't match Okta user	Check UPN resolution in log
HTTP 403	Scope not granted	Grant okta.users.read on the app
EA shows "Not Available"	Plist doesn't exist yet	Ensure password status policy has run


Log file:

tail -f /var/log/yourorg_password_status.log

okta-password-status/
├── README.md
├── scripts/
│   ├── yourorg_seed_okta_keychain.zsh
│   └── yourorg_okta_password_status.zsh
└── extension-attributes/
    ├── ea_okta_password_age.zsh
    ├── ea_okta_password_days_remaining.zsh
    ├── ea_okta_password_expired.zsh
    └── ea_okta_user_status.zsh



Thoughts
Copy thoughts to clipboard

Cleaned Up README.md
markdown
# Okta Password Status for macOS

> Retrieve Okta password expiry data via the Users API using OAuth 2.0 `private_key_jwt` authentication.  
> Persist to a local plist for Jamf Pro Extension Attribute reporting and Smart Group targeting.

[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)]()
[![IdP](https://img.shields.io/badge/IdP-Okta-blue)]()
[![MDM](https://img.shields.io/badge/MDM-Jamf%20Pro-purple)]()
[![Shell](https://img.shields.io/badge/shell-zsh-green)]()
[![Version](https://img.shields.io/badge/version-2.0.0-orange)]()

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Okta Configuration](#okta-configuration)
- [Jamf Pro Deployment](#jamf-pro-deployment)
- [Extension Attributes](#extension-attributes)
- [Smart Groups](#smart-groups)
- [Plist Schema](#plist-schema)
- [UPN Resolution](#upn-resolution)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [Repo Structure](#repo-structure)
- [Changelog](#changelog)

---

## Overview

Okta does not natively surface password expiry information on macOS endpoints. This project solves that gap with a two-policy approach:

1. **Keychain Seed Policy** — deploys the signing key to each Mac's System Keychain (runs once per computer)
2. **Password Status Policy** — queries Okta daily, calculates password age/expiry, and writes results to a local plist

Jamf Pro Extension Attributes read the plist, enabling Smart Groups for compliance reporting and automated remediation.

---

## Architecture

```text
┌──────────────────────────────────────────────────────────────┐
│  Jamf Policy: Seed Keychain (once per computer)               │
│  Parameter \$4 = DER private key (base64)                      │
│  Parameter \$5 = Okta Key ID (kid)                             │
└─────────────────────────────┬────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  System Keychain (root-only)                                  │
│  Service: com.yourcompany.okta.passwordstatus                 │
│  ├── Account: private-key → base64(PEM)                       │
│  └── Account: key-id → kid                                    │
└─────────────────────────────┬────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  Jamf Policy: Password Status (daily)                         │
│  Parameter \$4 = Client ID                                     │
│  Parameter \$5 = Okta Domain                                   │
│  Parameter \$6 = Password Max Age Days                         │
│                                                               │
│  1. Reads key from Keychain                                   │
│  2. Signs JWT (private_key_jwt)                               │
│  3. Gets OAuth access token                                   │
│  4. Queries GET /api/v1/users/{upn}                           │
│  5. Writes plist                                              │
└─────────────────────────────┬────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  /Library/Application Support/yourorg/                         │
│  com.yourorg.passwordstatus.plist                              │
└─────────────────────────────┬────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  Jamf Pro Extension Attributes                                │
│  → Smart Groups for compliance + notifications                │
└──────────────────────────────────────────────────────────────┘
Prerequisites
Requirement	Details
macOS	15.0+ (Sequoia / Tahoe)
Jamf Pro	Managed endpoints with recurring check-in
Okta	OIE tenant with API Services app
python3	Must be installed on macOS
openssl	Pre-installed on macOS
Okta Configuration
Step 1: Create an API Services App
Navigate to Applications → Applications → Create App Integration
Select API Services
Name: Jamf Password Status
Click Save
Step 2: Generate a Key Pair
Run on your admin Mac:

bash
openssl genrsa -out /tmp/okta_private_key.pem 2048
Step 3: Generate the JWK
This converts your public key into a format Okta can accept:

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
Step 4: Register the Public Key in Okta
Go to Applications → Your App → General → Client Credentials → Edit
Set Client authentication to Public key / Private key
Disable DPoP (Proof of Possession → None)
Click Add Key → paste the JWK JSON from Step 3
Click Save — note the kid that Okta assigns
Step 5: Grant API Scope
Go to Okta API Scopes tab
Grant okta.users.read
Step 6: Generate DER Base64 for Jamf
This creates a shorter encoding that fits within Jamf's 2000-character parameter limit:

bash
openssl rsa -in /tmp/okta_private_key.pem -outform DER 2>/dev/null | base64 | tr -d '\n' | pbcopy
echo "✅ DER base64 copied to clipboard (~1624 chars)"
Step 7: Clean Up
bash
rm -f /tmp/okta_private_key.pem
Jamf Pro Deployment
Policy 1: Seed Keychain
Runs once per computer to store the private key securely.

Setting	Value
Name	Seed Okta Keychain Credentials
Trigger	Recurring Check-in
Frequency	Once per computer
Script	yourorg_seed_okta_keychain.zsh
Parameter 4	DER base64 private key (from Step 6)
Parameter 5	kid from Okta (from Step 4)
Policy 2: Password Status
Runs daily to query Okta and update the local plist.

Setting	Value
Name	Okta Password Status
Trigger	Login + Recurring Check-in
Frequency	Once per day
Script	yourorg_okta_password_status.zsh
Parameter 4	Client ID (from Okta app)
Parameter 5	Okta domain (e.g. yourorg.okta.com)
Parameter 6	Password max age days (e.g. 90)
Extension Attributes
All EAs follow the same pattern — read a single key from the plist:

EA Name	Plist Key
Okta Password Age	PasswordAgeDays
Okta Password Days Remaining	PasswordDaysRemaining
Okta Password Expired	PasswordExpired
Okta User Status	UserStatus
Each EA uses Data Type: String and Input Type: Script.

Smart Groups
Smart Group	Criteria	Purpose
Password Expiring Soon	EA "Okta Password Days Remaining" ≤ 14	Trigger notification policy
Password Expired	EA "Okta Password Expired" = "true"	Compliance reporting
Password Status Missing	EA "Okta Password Age" = "Not Available"	Deployment scoping
Plist Schema
Path: /Library/Application Support/yourorg/com.yourorg.passwordstatus.plist

Owner: root:wheel | Permissions: 644

Key	Type	Description
PasswordLastChanged	string	ISO 8601 timestamp of last password change
PasswordAgeDays	integer	Days since last password change
PasswordDaysRemaining	string	Days until expiry (or N/A if no policy)
PasswordExpired	bool	true / false
PasswordMaxAgeDays	integer	Max age from password policy
UserStatus	string	Okta status: ACTIVE, LOCKED_OUT, PASSWORD_EXPIRED, etc.
CredentialProvider	string	OKTA, ACTIVE_DIRECTORY, LDAP, etc.
OktaUPN	string	Resolved User Principal Name
LastLogin	string	Last Okta login timestamp
LastChecked	string	When the script last ran
ScriptVersion	string	Script version number
UPN Resolution
The script resolves the logged-in user's Okta UPN using the following priority:

Priority	Source	Method
1	Platform SSO	app-sso -l
2	Directory Services	dscl . read AltSecurityIdentities (PlatformSSO entry)
3	Okta Verify	UserContext.plist Email field
4	Fallback	{shortname}@yourorg.com
Security
Concern	Mitigation
Private key on disk	❌ Never — stored in System Keychain only
Key in script	❌ Never — retrieved at runtime
Who can read Keychain	root only (System Keychain)
Key in memory	Process substitution — never written, cleared on exit
Key rotation	Generate new pair → re-register in Okta → re-run seed policy
API scope	okta.users.read only — no write access
Troubleshooting
Symptom	Cause	Fix
Credentials not found in System Keychain	Seed policy hasn't run	Trigger seed policy manually
Token request failed	Wrong domain or DPoP enabled	Check parameter 5; disable DPoP in Okta
JWT signing failed	Key mismatch	Re-register JWK in Okta from same PEM
HTTP 404 for user	UPN doesn't match Okta user	Check UPN resolution in log
HTTP 403	Scope not granted	Grant okta.users.read on the app
EA shows "Not Available"	Plist doesn't exist yet	Ensure password status policy has run
Log file:

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
    └── ea_okta_user_status.zsh

Changelog
2.0.0 — 2026-05-13
OAuth 2.0 private_key_jwt authentication (no static tokens)
Private key stored in System Keychain (DER format for Jamf parameter limit)
python3 JSON parsing (no jq dependency)
UPN resolution via Platform SSO, AltSecurityIdentities, Okta Verify
Local password age fallback when Okta returns null
Automatic Jamf Pro inventory update on password date change

Credits

Okta Users API Documentation
Inspired by Scott Kendall's Entra ID password status script

