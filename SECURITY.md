# Security Policy

## Supported versions

Weir is pre-1.0. Only the latest released minor version receives security fixes. Updates arrive through Sparkle, so if you are on an older version, let the in-app updater run.

| Version            | Supported          |
|--------------------|--------------------|
| latest 0.x         | ✓                  |
| anything older     | ✗                  |

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Use GitHub's [private vulnerability reporting](https://github.com/nek0der/weir/security/advisories/new) instead. We aim to acknowledge within 72 hours and ship a fix for high-severity findings within 14 days.

## In scope

- Code-signing or notarization bypass
- Update channel tampering (Sparkle appcast / EdDSA misuse)
- Sandbox escape or privilege escalation through the embedded shell
- Secret / credential leakage from the bundled binary
- Path traversal or remote code execution (RCE) in the embedded `libghostty`

## Out of scope

- Issues that require existing local root or physical access
- Social engineering of the maintainer or users
- Vulnerabilities in third-party dependencies that Dependabot or GitHub Security Advisories already track (please report them upstream)
- Findings that reproduce only on macOS versions older than the supported deployment target (currently macOS 26 Tahoe)
