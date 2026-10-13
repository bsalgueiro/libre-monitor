# libre-monitor

A small, read-only desktop widget for your own FreeStyle Libre glucose data.

The phone app reads the sensor and uploads to LibreView. This project does **not** talk to the sensor.
It signs in to the unofficial LibreLinkUp follower API and only reads what the phone has already uploaded.

```
Sensor --> LibreLink (phone) --> LibreView cloud --> libre-monitor (desktop)
```

## Features

- Borderless, always-on-top corner widget: current value, trend arrow and a smooth graph with the 70-180 mg/dL band and a 100 reference line.
- Hover the graph for the value and time of any reading.
- 3, 6 or 12 hour range (mouse wheel or menu), mg/dL or mmol/L, light, dark or follow-the-system theme.
- Drag to move, drag any edge to resize, snap to a screen corner. Position and preferences are remembered.
- Right-click for the menu.
- Tray icon showing the current value on a range-coloured tile. The ✕ on the widget hides it to the tray; click the tray icon to bring it back. Use the menu's Exit to quit. If the tray icon is turned off, the ✕ exits instead.
- The follower login is stored encrypted with Windows DPAPI (current user only).

## Projects

| Project | Purpose |
|---|---|
| `LibreMonitor.Core` | LibreLinkUp client (login with regional redirect, patients, graph), polling monitor, unit conversion |
| `LibreMonitor.App` | WPF widget |
| `LibreMonitor.Cli` | Console check of the connection |
| `LibreMonitor.Core.Tests` | xUnit tests using fake HTTP responses (no network) |

## Setup

Requires Windows and the .NET 10 SDK.

1. In the LibreLink phone app open **Connected apps > LibreLinkUp** and invite a second email address.
2. Accept the invitation in the official LibreLinkUp app with that account (this also clears terms and email verification).
3. Run the widget and sign in with the **follower** account, not your main one:

```powershell
dotnet run --project src/LibreMonitor.App
```

To only check the connection from a console (credentials from `LIBRE_EMAIL` / `LIBRE_PASSWORD`, or prompted):

```powershell
dotnet run --project src/LibreMonitor.Cli
```

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

### Windows SmartScreen warning

The executable is not code-signed, so the first time someone runs it, Windows SmartScreen shows a blue
**"Windows protected your PC"** window. This is expected for any unsigned program from an unknown publisher; it does not
mean the file is damaged or unsafe. To run it:

1. Click **More info**.
2. Click **Run anyway**.

Windows remembers the choice for that file. If the file came from the internet, you can also tick **Unblock** in the
file's Properties before running it.

Removing the warning needs a code-signing certificate, which costs money every year. Some antivirus tools may also
flag the single-file build.

## Notes

- The API is unofficial and can change. The app version sent in headers lives in `LibreLinkUpOptions`.
- Requests must carry a User-Agent or the service answers HTTP 403. The client sends an honest one (`LibreMonitor/0.1`).
- The colours for low, in range and high are display only. They are not alarms.
- **Not a medical device. Do not make treatment decisions from this app.**
- Not affiliated with or endorsed by Abbott.

## Tests

```powershell
dotnet test
```

## Planned

Local history database, configurable alerts, CSV export.
