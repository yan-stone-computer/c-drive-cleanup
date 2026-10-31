# Security Policy

## Scope

This project performs destructive filesystem operations. Security review covers path containment, environment trust, privilege boundaries, process interruption, recovery-data preservation, and report privacy.

## Non-negotiable invariants

- A deletion target must be inside a built-in exact allowlist.
- `%TEMP%`, `%TMP%`, and `%LOCALAPPDATA%` must not expand the intended known-folder boundary.
- User content folders, volume roots, UNC roots, critical system directories, and reparse-point paths must be rejected.
- Real deletion requires both `-Apply` and `-Yes`.
- Restore points, `Windows.old`, and Windows upgrade remnants are not automatically deleted.
- BITS and Windows Update services are not stopped by cache cleanup.
- DISM must not be force-killed by this project.

## Reporting a vulnerability

Open a private GitHub Security Advisory:

https://github.com/yan-stone-computer/c-drive-cleanup/security/advisories/new

Do not include real usernames, full local paths, tokens, logs, or other personal data. A minimal synthetic reproduction is preferred.

## Safe validation

Only use temporary test fixtures. Do not demonstrate data-loss issues by cleaning a real system directory. The repository's test suite must remain non-destructive to the host outside uniquely created temporary folders.
