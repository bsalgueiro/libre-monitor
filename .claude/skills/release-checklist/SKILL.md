---
name: release-checklist
description: Prepare a Libre Monitor release (version tag). Use when the user asks to cut, tag or publish a release. Never tags or pushes without explicit confirmation.
disable-model-invocation: true
---

1. Working tree clean, on `main`, up to date with origin.
2. Run `dotnet test` and `cd mac && swift test`. Report failures verbatim.
3. Confirm dev mode is absent from Release: Windows publish ignores `--dev`; Mac CI greps for `--simulate`.
4. Check version-bearing places agree: `LibreMonitor.App.csproj`, `mac/Resources/Info.plist`, `AppInfo` (C# and Swift), the User-Agent `LibreMonitor/x.y`.
5. Check README and `docs/index.html` match: asset names (`LibreMonitor-win-x64.exe`, `LibreMonitor-mac.zip`), OS requirements, features, warnings.
6. Check `THIRD-PARTY-NOTICES.md` reflects current dependencies.
7. Show the user the proposed tag (`vX.Y.Z`) and commands, then ask before `git tag` and `git push origin <tag>`.
8. After the workflow finishes: verify the release has both binaries, `SHA256SUMS.txt` and the notices file.
