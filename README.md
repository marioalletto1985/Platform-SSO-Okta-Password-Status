# Okta Password Status for Platform SSO

> Retrieve Okta password expiry data via the Okta Users API using OAuth 2.0 `private_key_jwt` authentication.  
> Persist the result to a local plist for Jamf Pro Extension Attribute reporting and Smart Group targeting.

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
- [Credits](#credits)

---

## Overview

Okta does not natively surface password expiry information on macOS endpoints.

This project solves that gap with a two-policy Jamf Pro workflow:

1. **Keychain Seed Policy**  
   Deploys the signing key to each Mac's System Keychain.  
   This runs once per computer.

2. **Password Status Policy**  
   Queries Okta daily, calculates password age and expiry, then writes the result to a local plist.

Jamf Pro Extension Attributes read the plist, enabling Smart Groups for compliance reporting, notifications, and automated remediation.

---

## Architecture

```text
┌──────────────────────────────────────────────────────────────┐
│ Jamf Policy: Seed Keychain Credentials                       │
│ Frequency: Once per computer                                 │
│                                                              │
│ Parameter $4 = DER private key, base64 encoded               │
│ Parameter $5 = Okta Key ID, kid                              │
└─────────────────────────────┬────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ System Keychain                                               │
│ Service: com.yourcompany.okta.passwordstatus                 │
│                                                              │
│ Account: private-key → base64 PEM                            │
│ Account: key-id      → kid                                   │
└─────────────────────────────┬────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ Jamf Policy: Okta Password Status                            │
│ Frequency: Once per day                                      │
│                                                              │
│ Parameter $4 = Client ID                                     │
│ Parameter $5 = Okta Domain                                   │
│ Parameter $6 = Password Max Age Days                         │
│                                                              │
│ 1. Reads key from Keychain                                   │
│ 2. Signs JWT using private_key_jwt                           │
│ 3. Requests OAuth access token                               │
│ 4. Queries GET /api/v1/users/{upn}                           │
│ 5. Writes local plist                                        │
└─────────────────────────────┬────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ /Library/Application Support/yourorg/                        │
│ com.yourorg.passwordstatus.plist                             │
└─────────────────────────────┬────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ Jamf Pro Extension Attributes                                │
│ Smart Groups for compliance and notifications                │
└──────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

| Requirement | Details |
|---|---|
| macOS | macOS 15.0 or later |
| Jamf Pro | Managed endpoints with recurring check-in |
| Okta | Okta Identity Engine tenant with API Services app |
| python3 | Must be installed on macOS |
| openssl | Pre-installed on macOS |

---

## Okta Configuration

### Step 1: Create an API Services App

In the Okta Admin Console:

1. Go to **Applications**.
2. Select **Applications**.
3. Click **Create App Integration**.
4. Select **API Services**.
5. Name the app, for example:

```text
Jamf Password Status
```

6. Click **Save**.

---

### Step 2: Generate a Key Pair

Run the following on your admin Mac:

```bash
openssl genrsa -out /tmp/okta_private_key.pem 2048
```

---

### Step 3: Generate the JWK

This converts the public key into a JSON Web Key format that Okta can accept.

```bash
MODULUS_HEX=$(openssl rsa -in /tmp/okta_private_key.pem -modulus -noout 2>/dev/null | cut -d= -f2)
KID=$(uuidgen | tr '[:upper:]' '[:lower:]')

python3 -c "
import base64
import json

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
```

---

### Step 4: Register the Public Key in Okta

1. Go to **Applications**.
2. Open your API Services app.
3. Go to **General**.
4. Under **Client Credentials**, click **Edit**.
5. Set **Client authentication** to:

```text
Public key / Private key
```

6. Set **Proof of Possession** / **DPoP** to:

```text
None
```

7. Click **Add Key**.
8. Paste the JWK JSON generated in the previous step.
9. Click **Save**.
10. Note the `kid` assigned in Okta.

---

### Step 5: Grant API Scope

In the same Okta app:

1. Go to the **Okta API Scopes** tab.
2. Grant the following scope:

```text
okta.users.read
```

---

### Step 6: Generate DER Base64 for Jamf

This creates a shorter encoded private key that fits within Jamf Pro's script parameter character limit.

```bash
openssl rsa -in /tmp/okta_private_key.pem -outform DER 2>/dev/null | base64 | tr -d '\n' | pbcopy

echo "DER base64 copied to clipboard"
```

The result is usually around 1,600 characters.

---

### Step 7: Clean Up

Remove the private key from your admin Mac after copying the DER base64 value into Jamf Pro.

```bash
rm -f /tmp/okta_private_key.pem
```

---

## Jamf Pro Deployment

### Policy 1: Seed Keychain Credentials

This policy stores the private key and Okta `kid` in the System Keychain.

| Setting | Value |
|---|---|
| Name | Seed Okta Keychain Credentials |
| Trigger | Recurring Check-in |
| Frequency | Once per computer |
| Script | `yourorg_seed_okta_keychain.zsh` |
| Parameter 4 | DER base64 private key |
| Parameter 5 | Okta `kid` |

---

### Policy 2: Okta Password Status

This policy queries Okta and updates the local plist.

| Setting | Value |
|---|---|
| Name | Okta Password Status |
| Trigger | Login + Recurring Check-in |
| Frequency | Once per day |
| Script | `yourorg_okta_password_status.zsh` |
| Parameter 4 | Client ID |
| Parameter 5 | Okta domain, for example `yourorg.okta.com` |
| Parameter 6 | Password max age days, for example `90` |

---

## Extension Attributes

All Extension Attributes read a single key from the local plist.

| Extension Attribute Name | Plist Key |
|---|---|
| Okta Password Age | `PasswordAgeDays` |
| Okta Password Days Remaining | `PasswordDaysRemaining` |
| Okta Password Expired | `PasswordExpired` |
| Okta User Status | `UserStatus` |

Recommended Jamf Pro settings:

| Setting | Value |
|---|---|
| Data Type | String |
| Input Type | Script |

---

## Smart Groups

| Smart Group | Criteria | Purpose |
|---|---|---|
| Password Expiring Soon | `Okta Password Days Remaining` less than or equal to `14` | Trigger notification policy |
| Password Expired | `Okta Password Expired` is `true` | Compliance reporting |
| Password Status Missing | `Okta Password Age` is `Not Available` | Deployment scoping |

---

## Plist Schema

Path:

```text
/Library/Application Support/yourorg/com.yourorg.passwordstatus.plist
```

Recommended ownership and permissions:

```text
Owner: root:wheel
Permissions: 644
```

| Key | Type | Description |
|---|---|---|
| `PasswordLastChanged` | string | ISO 8601 timestamp of last password change |
| `PasswordAgeDays` | integer | Days since last password change |
| `PasswordDaysRemaining` | string | Days until expiry, or `N/A` if no policy applies |
| `PasswordExpired` | bool | `true` or `false` |
| `PasswordMaxAgeDays` | integer | Maximum password age from policy |
| `UserStatus` | string | Okta status, for example `ACTIVE`, `LOCKED_OUT`, or `PASSWORD_EXPIRED` |
| `CredentialProvider` | string | Credential provider, for example `OKTA`, `ACTIVE_DIRECTORY`, or `LDAP` |
| `OktaUPN` | string | Resolved User Principal Name |
| `LastLogin` | string | Last Okta login timestamp |
| `LastChecked` | string | Timestamp of the last script run |
| `ScriptVersion` | string | Script version number |

---

## UPN Resolution

The script resolves the logged-in user's Okta UPN using the following priority order.

| Priority | Source | Method |
|---|---|---|
| 1 | Platform SSO | `app-sso -l` |
| 2 | Directory Services | `dscl . read AltSecurityIdentities` Platform SSO entry |
| 3 | Okta Verify | `UserContext.plist` Email field |
| 4 | Fallback | `{shortname}@yourorg.com` |

---

## Security

| Concern | Mitigation |
|---|---|
| Private key on disk | Not stored on disk after deployment |
| Key in script | Never embedded in the script |
| Key storage | Stored in the System Keychain |
| Keychain access | Root-only access |
| Key in memory | Used at runtime only and cleared on exit |
| Key rotation | Generate new pair, register in Okta, then re-run seed policy |
| API scope | `okta.users.read` only |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Credentials not found in System Keychain | Seed policy has not run | Trigger the seed policy manually |
| Token request failed | Wrong domain or DPoP enabled | Check Parameter 5 and disable DPoP |
| JWT signing failed | Key mismatch | Re-register the JWK in Okta from the same PEM |
| HTTP 404 for user | UPN does not match an Okta user | Check UPN resolution in the log |
| HTTP 403 | Scope not granted | Grant `okta.users.read` on the app |
| EA shows `Not Available` | Plist does not exist yet | Ensure the password status policy has run |

Log file:

```bash
tail -f /var/log/yourorg_password_status.log
```

---

## Repo Structure

```text
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
```

---

## Changelog

### 2.0.0 — 2026-05-13

- Added OAuth 2.0 `private_key_jwt` authentication.
- Removed dependency on static API tokens.
- Added System Keychain storage for the private key.
- Added DER private key format support for Jamf Pro parameter limits.
- Added Python 3 JSON parsing.
- Removed `jq` dependency.
- Added UPN resolution through:
  - Platform SSO
  - `AltSecurityIdentities`
  - Okta Verify
- Added local password age fallback when Okta returns `null`.
- Added automatic Jamf Pro inventory update when password date changes.

---

## Credits

- Okta Users API Documentation
- Inspired by Scott Kendall's Entra ID password status script
