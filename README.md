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
