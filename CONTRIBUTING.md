# Contributing

Thanks for helping. This is a small hobby project, so keep changes focused and easy to review.

## Scope rules

These keep the app safe and simple. Changes that break them will not be merged.

- **Read-only.** The app only reads from LibreView (the login request aside). It never changes account or sensor data.
- **No glucose data on disk.** Only the encrypted login and preferences are stored. History and exports are out of scope.
  The insulin reminder adds one timestamp, the last "administered" tap, and nothing more: no doses, amounts or history.
- **Nothing leaves the machine** except requests to LibreView.
- **No sensor protocol work** and no extraction of keys or data from the phone app or the sensor.
- **No medical claims.** The app is not a medical device and alerts are not a safety system.
- **Never paste credentials**, tokens or real glucose history into issues, pull requests or tests.

## Setup and tests

See the developer sections of the [README](README.md#for-developers).

```powershell
dotnet test            # Windows app and core library
```

```bash
cd mac && swift test   # macOS app (on a Mac)
```

Add or update tests with your change. Tests use fake HTTP responses and must not contact the network.

## Pull requests

- One topic per pull request, with a short description of what changed and why.
- Match the style of the surrounding code.
- Commit messages: a short imperative summary line, such as "Add the option to hide the graph".
- If you change how the app talks to the service, say how you checked it.

## Licence

By contributing you agree that your code is released under the [MIT licence](LICENSE) and your documentation changes
under [CC BY 4.0](LICENSE-DOCS.md).
