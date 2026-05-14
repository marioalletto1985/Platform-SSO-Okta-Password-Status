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
