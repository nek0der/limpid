# Security Policy

## Supported versions

Limpid is pre-1.0. Only the latest released minor version receives security fixes; auto-updates flow through Sparkle, so users on outdated versions should let the in-app updater run.

| Version            | Supported          |
|--------------------|--------------------|
| latest 0.x         | :white_check_mark: |
| anything older     | :x:                |

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Use GitHub's [private vulnerability reporting](https://github.com/nek0der/limpid/security/advisories/new) instead. I aim to acknowledge within 72 hours and ship a fix for high-severity findings within 14 days.

## In scope

- Code-signing or notarization bypass
- Update channel tampering (Sparkle appcast / EdDSA misuse)
- Sandbox escape or privilege escalation through the embedded shell
- Secret / credential leakage from the bundled binary
- Path-traversal or RCE in the embedded `libghostty`

## Out of scope

- Issues that require existing local root or physical access
- Social engineering of the maintainer or users
- Vulnerabilities in third-party dependencies that are already tracked by Dependabot or GitHub Security Advisories (please file upstream)
- Findings only reproducible on macOS versions older than the supported deployment target (currently macOS 26 Tahoe)
