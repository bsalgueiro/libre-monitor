# Libre Monitor

Read-only desktop widget showing FreeStyle Libre glucose (Windows WPF/.NET 10, macOS Swift package). It signs in to the
unofficial LibreLinkUp follower service and displays what the phone already uploaded. Hobby project, MIT code, CC BY 4.0 docs.
Site: https://bsalgueiro.github.io/libre-monitor/ (source: `docs/index.html`, served from `main` /docs).

## Layout

Two self-contained platform folders, `windows/` and `mac/`, plus shared `docs/` (website) and repo-level files.

- `windows/src/LibreMonitor.Core` (client, monitor, alerts, models) / `.App` (WPF) / `.Cli`; tests in `windows/tests/LibreMonitor.Core.Tests`.
- `mac/Sources/LibreMonitorKit` (Swift port of Core) / `LibreMonitorMac` (AppKit/SwiftUI UI); tests in `mac/Tests`.
- Core and Kit are deliberate twins. File names match (Alerts, GlucoseMonitor, LibreLinkUpClient, Models, DevMode/DevOptions).

## Non-negotiable rules (from CONTRIBUTING.md and SECURITY.md)

1. Read-only: only the login request writes anything to LibreView.
2. No glucose data on disk. Only the encrypted login (DPAPI / Keychain) and preferences. No history, no CSV export.
   The insulin reminder also keeps one timestamp (last "taken" tap). Never store dose amounts or a list of past doses.
3. Network traffic goes only to LibreView hosts. Keep the check that the regional redirect stays on the service's own hosts.
4. No sensor protocol work, no key extraction.
5. No medical claims. The insulin reminder is a memory aid: no dosing advice, no amounts, and its text must stay neutral ("not marked as taken yet", never "take your insulin"). Never describe alerts as a safety system. Keep the "not a medical device" wording.
6. Never put credentials, tokens or real glucose data in code, tests, issues, logs or commits.
7. Dev mode (`--dev`, `--simulate`) must not exist in Release builds. On Mac, CI greps the release binary for `--simulate`; do not weaken that.
8. Tests use fake HTTP and never touch the network.

## Working conventions

- **Cross-platform parity:** a behaviour change in Core (alert rules, error classification, polling, units) must be mirrored in
  LibreMonitorKit with matching tests, and vice versa. If you can only run one toolchain, say so and list what is unmirrored.
- **Alert rules** live only in `Alerts.cs` / `Alerts.swift` with no UI or clock. Thresholds are stored in mg/dL regardless of display unit.
- **Failure classification:** unexpected responses (403/404/410, non-zero API status, HTML instead of JSON, missing field, bad timestamp)
  are `ServiceChanged`, never "wrong password". Server errors and rate limits stay retryable. Raised after 3 in a row.
- If Abbott rejects the client, update `LibreLinkUpOptions.AppVersion` (and the Swift equivalent). Keep an honest User-Agent (required, else 403).
- Match surrounding style. Small focused changes. Commit messages: short imperative summary ("Add the option to hide the graph").
- Update README, `docs/index.html` and `THIRD-PARTY-NOTICES.md` when behaviour, downloads or dependencies change. They must agree.

## Commands

```
dotnet test                                   # Windows only for the App; Core tests run anywhere with .NET 10
dotnet run --project windows/src/LibreMonitor.App -- --dev
cd mac && swift test
cd mac && ./scripts/make-app.sh --debug && open build/LibreMonitor.app --args --dev   # flags go to the app, not the script
```

Releases: push tag `vX.Y.Z`; `.github/workflows/release.yml` builds, tests, checksums and uploads. Do not tag or push without asking.

## Writing style (README, site, UI strings)

Plain, friendly, direct; written for non-programmers in user sections. Be upfront about limits (unsigned apps, unofficial API,
can stop working). Keep disclaimers; do not soften them. British spellings appear in places ("Centre", "Licence"); follow the file you edit.
Avoid hype and em dashes.

## Known gaps worth knowing

- Windows exe has not been tested on a clean machine (README says so). Keep that statement accurate.
- Windows and Mac each have their own CI workflow (`windows.yml`, `mac.yml`); `release.yml` publishes both only if both pass.
