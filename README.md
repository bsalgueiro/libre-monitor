# libre-monitor

A small, read-only desktop widget for your own FreeStyle Libre glucose data.

The phone app reads the sensor and uploads to LibreView. This project does **not** talk to the sensor.
It signs in to the unofficial LibreLinkUp follower API and only reads what the phone has already uploaded.

```
Sensor --> LibreLink (phone) --> LibreView cloud --> libre-monitor (desktop)
```

> **Not a medical device. Do not make treatment decisions from this app.**
> Not affiliated with or endorsed by Abbott.

**Contents:** [For users](#for-users) · [For developers](#for-developers)

---

# For users

Everything you need to install and use the widget. No programming knowledge required.

## What it does

- Borderless, always-on-top corner widget: current value, trend arrow and a smooth graph with the 70-180 mg/dL band and a 100 reference line.
- Hover the graph for the value and time of any reading.
- 3, 6 or 12 hour range, mg/dL or mmol/L, and a light, dark or follow-the-system theme.
- Tray icon showing the current value on a coloured tile.
- Optional low and high [alerts](#alerts) with your own limits: a Windows notification, a sound and a coloured widget border, with reminders and snooze.
- Your follower login is stored encrypted for your Windows user only. It is never shown or sent anywhere except to LibreView.
- It only reads data. It never changes anything in your account.
- It does **not** keep your glucose history. It shows what LibreView provides at the moment, and nothing about your
  readings is saved on your PC. For history, reports and sharing, use LibreView.

The colours for low, in range and high are for display only. They are not alarms.

## Getting started

You need Windows 10 or 11 (64-bit). There is nothing to install and no need to build anything: you download one file
and run it.

1. In the LibreLink phone app open **Connected apps > LibreLinkUp** and invite a second email address.
2. Accept the invitation in the official LibreLinkUp app with that account. This also clears the terms and email
   verification that the sign-in needs.
3. Download **`LibreMonitor-win-x64.exe`** from the
   [latest release](https://github.com/bsalgueiro/libre-monitor/releases/latest) (under *Assets*).
4. Run it and sign in with the **follower** account, not your main one.
   If Windows shows a blue warning, see [Windows SmartScreen warning](#windows-smartscreen-warning).

Optional: to check the download is intact, compare the output of
`Get-FileHash .\LibreMonitor-win-x64.exe -Algorithm SHA256` with the line in `SHA256SUMS.txt` from the same release.

## Using the widget

| To do this | Do this |
|---|---|
| Move it | Drag it |
| Resize it | Drag any edge or corner |
| Change the time range | Mouse wheel over the widget, or the menu |
| See a reading's value and time | Hover the graph |
| Open the menu | Right-click the widget |
| Switch mg/dL and mmol/L | Menu > Units |
| Light, dark or follow Windows | Menu > Appearance |
| Set up low and high alerts | Menu > Alerts... |
| Pause alerts for a while | Menu > Snooze alerts |
| Snap to a screen corner | Menu > Move to corner |
| Hide it to the tray | Click the ✕, or Menu > Hide to tray |
| Bring it back | Click the tray icon |
| Quit | Menu > Exit, or the tray icon's menu |
| Turn the tray icon off | Menu > untick Show tray icon (the ✕ then exits instead of hiding) |
| Sign out | Menu > Sign out and exit |

Position, size and preferences are remembered.

## Alerts

Open **Menu > Alerts...** to turn on a low alert, a high alert, or both, and set your own limits (in mg/dL or mmol/L,
whichever the widget shows). They are **off until you turn them on**. Use **Send test alert** to see what one looks like.

- **When it alerts:** once, when a reading goes below the low limit or above the high limit. The widget border also turns
  red (low) or amber (high) while the reading stays out of range.
- **Reminders:** while still out of range you can be reminded every 15, 30 or 60 minutes, or not at all.
- **No repeated alerts at the limit:** after an alert, the reading has to come back at least 5 mg/dL (about 0.3 mmol/L) inside
  the range before the next crossing counts as a new alert, so a value hovering on the line does not alert over and over.
- **Snooze:** **Menu > Snooze alerts** pauses notifications for 30 minutes, 1 hour or 2 hours. If you are still out of range
  when the snooze ends, you are alerted then.
- **Old readings are ignored:** a reading more than 10 minutes old does not trigger an alert.
- **Notifications need the tray icon.** If you turn the tray icon off, alerts still play the sound and colour the border.

**Do not rely on these alerts for safety.** They only work while this app is running, your PC is on and awake, and your
phone is uploading to LibreView. Readings can arrive minutes late, and Windows can hide notifications (for example in
Focus assist or Do not disturb). Keep your sensor's own alarms on.

## Windows SmartScreen warning

The executable is not code-signed, so the first time someone runs it, Windows SmartScreen shows a blue
**"Windows protected your PC"** window. This is expected for any unsigned program from an unknown publisher; it does not
mean the file is damaged or unsafe. To run it:

1. Click **More info**.
2. Click **Run anyway**.

Windows remembers the choice for that file. If the file came from the internet, you can also tick **Unblock** in the
file's Properties before running it.

Removing the warning needs a code-signing certificate, which costs money every year. Some antivirus tools may also
flag the single-file build.

---

# For developers

Building, running from source, testing and the technical background.

## Projects

| Project | Purpose |
|---|---|
| `LibreMonitor.Core` | LibreLinkUp client (login with regional redirect, patients, graph), polling monitor, unit conversion |
| `LibreMonitor.App` | WPF widget |
| `LibreMonitor.Cli` | Console check of the connection |
| `LibreMonitor.Core.Tests` | xUnit tests using fake HTTP responses (no network) |

## Run from source

Requires Windows and the .NET 10 SDK. Set up the follower account first (steps 1 and 2 under
[Getting started](#getting-started)), then:

```powershell
dotnet run --project src/LibreMonitor.App
```

To only check the connection from a console (credentials from `LIBRE_EMAIL` / `LIBRE_PASSWORD`, or prompted):

```powershell
dotnet run --project src/LibreMonitor.Cli
```

## Tests

```powershell
dotnet test
```

Tests use fake HTTP responses and never contact the network.

## Developer mode

Running from source with `--dev` adds a **Developer: simulate reading** entry to the widget menu. It fakes a reading for
each colour state (low, in range, high, old, none) so the display can be checked without waiting for real glucose to
change. The widget and the tray tooltip say SIMULATED while it is active.

```powershell
dotnet run --project src/LibreMonitor.App -- --dev
dotnet run --project src/LibreMonitor.App -- --simulate 2   # start with scenario 2 showing
```

This only exists in Debug builds. A Release or published executable ignores `--dev` and `--simulate`, so it can never
show a simulated value.

## Building an executable

Both builds below are Release builds, so developer mode cannot appear in them, even if started with `--dev`.
`dotnet run` and `dotnet build` without `-c Release` make Debug builds, which are the ones that accept `--dev`.
The `publish` folder is ignored by git.

**For yourself (small).** Needs the .NET 10 Desktop Runtime on the machine that runs it, which most PCs do not have.

```powershell
dotnet publish src/LibreMonitor.App -c Release -o publish
```

This produces `publish\LibreMonitor.App.exe` and a few supporting files, about 0.3 MB in total.

**For sharing with other people (self-contained).** Carries its own copy of .NET, so nothing needs to be installed.

```powershell
dotnet publish src/LibreMonitor.App -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
  -o publish
```

This produces a single `publish\LibreMonitor.App.exe` of about 72 MB for 64-bit Windows 10 or 11. It started and ran
with .NET removed from the environment, but it has not been tried on a clean machine. Because it bundles its own .NET,
it does not receive .NET security updates unless it is rebuilt and handed out again.

Whoever receives the executable will see the [SmartScreen warning](#windows-smartscreen-warning), because it is unsigned.

## Publishing a release

Users download the executable from the repository's Releases page. A release is made by pushing a version tag:

```powershell
git tag v0.1.0
git push origin v0.1.0
```

The workflow in `.github/workflows/release.yml` then runs the tests, publishes the self-contained single-file build
above with the version taken from the tag, and creates a release with generated notes and two files:
`LibreMonitor-win-x64.exe` and `SHA256SUMS.txt`. (A local build of the same command is named
`LibreMonitor.App.exe`; the workflow renames it.)

Downloads from the Releases page are only available to people who can see the repository, so it has to be public for
anyone else to use them.

## Technical notes

- The LibreLinkUp API is unofficial and can change. The app version sent in headers lives in `LibreLinkUpOptions`.
- Requests must carry a User-Agent or the service answers HTTP 403. The client sends an honest one (`LibreMonitor/0.1`).
- The follower login is encrypted with Windows DPAPI (current user scope) in `%LOCALAPPDATA%\LibreMonitor`, next to the
  widget's settings file.
- Alert rules live in `LibreMonitor.Core/Alerts.cs` (`AlertEvaluator`) with no UI or clock of its own, so every rule is
  covered by unit tests in `AlertTests.cs`. Thresholds are stored in mg/dL in `settings.json` whatever unit is displayed.
  In developer mode, simulated readings go through the same alert path, so alerts can be tried without real glucose
  changing (the notification says SIMULATED).
- No glucose data is written to disk, on purpose: the only files are the encrypted login and `settings.json`
  (preferences and alert limits). Recording history, and anything built on it such as a CSV export, is deliberately out
  of scope, because LibreView already keeps the user's history.
- The client never uploads or changes data. Apart from the login request, it only reads.
