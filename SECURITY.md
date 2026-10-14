# Security

## Reporting a problem

Please report security problems **privately** through GitHub: open the repository's **Security** tab and choose
**Report a vulnerability**. Do not open a public issue for them.

This is a hobby project maintained by one person. Expect a reply when time allows, not on a fixed schedule.

## What counts

- How the login is stored or handled (Windows DPAPI file, macOS Keychain), or anything that could expose it.
- The check that the regional login redirect stays on the service's own hosts.
- The developer-mode gate: a release build must never accept `--dev` or `--simulate`.
- Anything that would make the app send data anywhere other than LibreView, or change data there.

Changes by Abbott to their unofficial interface are not security problems; see the README for how the app reports them.

## Supported versions

Only the latest release.

## Safe use

Use a separate LibreLinkUp follower account, as the README describes, never your main account. Never share your password
or tokens in an issue.
