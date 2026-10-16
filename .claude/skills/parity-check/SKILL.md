---
name: parity-check
description: After changing Core (C#) or LibreMonitorKit (Swift) logic, verify the other platform has the matching change and tests. Use before committing any change to alerts, monitor, client, models or units.
---

1. `git diff` and list changed files under `windows/src/LibreMonitor.Core` or `mac/Sources/LibreMonitorKit` (and their tests).
2. For each, open the twin (Alerts, GlucoseMonitor, LibreLinkUpClient, Models, DevOptions/DevMode, Exceptions/Errors) and compare
   the behaviour: constants (5 mg/dL hysteresis, 10 min stale limit, 3-strike ServiceChanged, reminder intervals), error classification, unit rounding.
3. Check that the twin test file has an equivalent test for each new or changed case.
4. Run what is available: `dotnet test windows/tests/LibreMonitor.Core.Tests` and/or `cd mac && swift test`.
5. Report: mirrored / not mirrored / not run (and why). Do not claim parity for a toolchain you could not run.
