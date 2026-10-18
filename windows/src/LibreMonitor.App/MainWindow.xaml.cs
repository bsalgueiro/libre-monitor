using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using LibreMonitor.Core;
using Microsoft.Win32;

namespace LibreMonitor.App;

public partial class MainWindow : Window
{
#if DEBUG
    // Built and run from source: developer features may be switched on with --dev.
    private const bool DevBuild = true;
#else
    // Release / published executable: developer features can never appear, whatever the command line says.
    private const bool DevBuild = false;
#endif

    private static readonly int[] RangeChoices = [3, 6, 12];
    private static readonly TimeSpan StaleAfter = TimeSpan.FromMinutes(10);
    private const double ScreenInset = 4; // plus the 12px shadow margin gives a 16px gap to the screen edge

    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(30) };
    private readonly LibreLinkUpClient _client;
    private readonly CredentialStore _store = new();
    private readonly WidgetSettings _settings = WidgetSettings.Load();
    private readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromSeconds(15) };
    private readonly TrayController _tray;

    private GlucoseMonitor? _monitor;
    private (string Email, string Password) _credentials;
    private readonly AlertEvaluator _alerts = new();
    private readonly InsulinReminderEvaluator _insulinReminder = new();
    private readonly SensorExpiryEvaluator _sensorExpiry = new();
    private MonitorUpdate? _last;
    private MonitorUpdate? _lastReal;           // newest real update, kept while a simulation is showing
    private SimulationScenario? _simulation;    // developer branch: fake readings for checking colours
    private readonly List<(MenuItem Item, int Index)> _simulationItems = [];
    private string? _problem;
    private DateTimeOffset _updatingUntil = DateTimeOffset.MinValue; // shows "updating…" after a manual refresh
    private bool _problemIsFatal;
    private bool _serviceChanged;

    public MainWindow()
    {
        InitializeComponent();
        _client = new LibreLinkUpClient(_http);
        BuildSensorDurationMenu();

        _tray = new TrayController(() => IsVisible, ToggleWidget, Close) { Visible = _settings.ShowTrayIcon };

        Topmost = _settings.Topmost;
        Graph.Hours = RangeChoices.Contains(_settings.Hours) ? _settings.Hours : 6;
        Graph.Unit = _settings.Unit;
        ApplyGraphMode(); // sets the minimum size for the mode before the saved size is applied
        ApplyTheme();
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;

        var (savedWidth, savedHeight) = SizeForCurrentMode();
        if (savedWidth is { } width && savedHeight is { } height)
        {
            Width = Math.Clamp(width, MinWidth, MaxWidth);
            Height = Math.Clamp(height, MinHeight, MaxHeight);
        }
        else if (!_settings.ShowGraph)
        {
            Width = CompactDefaultWidth;
            Height = CompactDefaultHeight;
        }

        ApplyPosition();

        // Developer mode (simulated readings) needs both a Debug build and --dev; see DevOptions.
        var dev = DevOptions.Parse(Environment.GetCommandLineArgs(), allowed: DevBuild);
        if (dev.Enabled) BuildSimulationMenu();
        if (dev.Scenario is { } scenario) Simulate(scenario);

        _tick.Tick += (_, _) =>
        {
            // A simulated reading is rebuilt each tick so it does not age into the grey "old reading" state.
            if (_simulation is not null) ShowSimulation();
            else { RenderAge(); Graph.Refresh(); EvaluateAlerts(); }
            EvaluateInsulin(); // follows the clock, not the readings, so it runs whatever the glucose state is
            EvaluateSensor();
        };
        _tick.Start();

        Loaded += async (_, _) =>
        {
            EvaluateInsulin();
            await StartAsync();
        };
        Closed += async (_, _) =>
        {
            SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
            _tray.Dispose();
            _settings.Save();
            if (_monitor is not null) await _monitor.StopAsync();
            _http.Dispose();
        };
    }

    private async Task StartAsync()
    {
        var saved = _store.Load();
        if (saved is null)
        {
            var login = new LoginWindow(_client);
            if (login.ShowDialog() != true || login.Result is not { } entered)
            {
                Close();
                return;
            }

            _store.Save(entered.Email, entered.Password);
            saved = entered;
        }

        _credentials = saved.Value;
        _monitor = new GlucoseMonitor(_client, () => _credentials);
        _monitor.Updated += update => Dispatcher.BeginInvoke(() =>
        {
            _lastReal = update;
            if (_simulation is null) OnUpdated(update);
        });
        _monitor.Failed += (ex, fatal) => Dispatcher.BeginInvoke(() =>
        {
            if (_simulation is null) OnFailed(ex, fatal);
        });
        _monitor.ServiceChanged += ex => Dispatcher.BeginInvoke(() =>
        {
            if (_simulation is null) OnServiceChanged(ex);
        });
        _monitor.Start();
        await Task.CompletedTask;
    }

    private void OnUpdated(MonitorUpdate update)
    {
        _updatingUntil = DateTimeOffset.MinValue;
        _last = update;
        _problem = null;
        _serviceChanged = false; // a good answer ends the episode

        var readings = update.Snapshot.History.ToList();
        if (update.Snapshot.Current is { } current && (readings.Count == 0 || current.TimestampUtc > readings[^1].TimestampUtc))
        {
            readings.Add(current);
        }

        Graph.Readings = readings;
        RenderValue();
        RenderAge();
        EvaluateAlerts();
        EvaluateSensor();
    }

    // ---- alerts ----------------------------------------------------------------------------

    private void EvaluateAlerts()
    {
        var now = DateTimeOffset.UtcNow;
        var raised = _alerts.Evaluate(_settings.Alerts, _last?.Snapshot.Current, now);
        if (raised is not null) Deliver(raised, now);

        UpdateAlertBorder(now);
    }

    private void Deliver(AlertRaised alert, DateTimeOffset now)
    {
        var unit = _settings.Unit;
        var low = alert.Kind == AlertKind.Low;
        // One message, however many times it repeats: the title says what it is, the body carries the reading.
        var title = (_simulation is not null ? "SIMULATED · " : string.Empty) + $"{(low ? "Low" : "High")} glucose alert";
        var text = $"{GlucoseUnits.Format(alert.Reading.MgPerDl, unit, CultureInfo.CurrentCulture)} {unit.Label()} "
            + $"{alert.Reading.Trend.ToArrow()} · {FormatAge(now - alert.Reading.TimestampUtc)}";

        // The notification needs the tray icon. Without it the sound and the widget border still work.
        _tray.Notify(title, text);
        if (_settings.Alerts.Sound) System.Media.SystemSounds.Exclamation.Play();
    }

    /// <summary>A coloured border while the current reading is inside an alert zone, regardless of snooze.</summary>
    private void UpdateAlertBorder(DateTimeOffset now)
    {
        var zone = AlertEvaluator.Classify(_settings.Alerts, _last?.Snapshot.Current, now);
        if (zone is null)
        {
            Card.SetResourceReference(Border.BorderBrushProperty, "CardBorderBrush");
            Card.BorderThickness = new Thickness(1);
            return;
        }

        Card.BorderBrush = Palette.Brush(zone == AlertKind.Low ? Palette.Low : Palette.High);
        Card.BorderThickness = new Thickness(2);
    }

    private void Alerts_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new AlertsWindow(_settings.Alerts, _settings.Insulin, _settings.Unit, TestAlert) { Owner = this };
        if (dialog.ShowDialog() != true || dialog.Result is not { } result || dialog.InsulinResult is not { } insulin) return;

        _settings.Alerts = result;
        _settings.Insulin = insulin.Enabled ? insulin : insulin with { LastAdministeredAt = null }; // off means nothing stays saved
        _settings.Save();
        _alerts.Reset(); // new thresholds start a fresh episode
        _insulinReminder.Reset();
        EvaluateAlerts();
        EvaluateInsulin();
    }

    // ---- sensor ----------------------------------------------------------------

    /// <summary>The sensor the service named in the latest answer, or null when it did not name one (or a simulation is showing).</summary>
    private SensorInfo? CurrentSensor => _simulation is null ? _last?.Snapshot.Sensor : null;

    private void EvaluateSensor()
    {
        var now = DateTimeOffset.UtcNow;
        var raised = _sensorExpiry.Evaluate(CurrentSensor, now, _alerts.SnoozedUntil(now), SensorDuration);
        if (raised is not null)
        {
            _tray.Notify("Sensor reminder", $"The sensor is due to end about {Stamp(raised.EndsAt)}.");
        }
    }

    /// <summary>The duration the user chose for their sensor, always one of the choices.</summary>
    private int SensorDuration => SensorSchedule.NormalizeDurationDays(_settings.SensorDurationDays);

    private readonly List<MenuItem> _sensorDurationItems = [];

    /// <summary>One menu entry per choice, so a new duration only needs adding to <see cref="SensorSchedule.DurationChoices"/>.</summary>
    private void BuildSensorDurationMenu()
    {
        foreach (var days in SensorSchedule.DurationChoices)
        {
            var item = new MenuItem { Header = $"{days} days", Tag = days };
            item.Click += SensorDuration_Click;
            SensorDurationMenu.Items.Add(item);
            _sensorDurationItems.Add(item);
        }
    }

    private void SensorDuration_Click(object sender, RoutedEventArgs e)
    {
        _settings.SensorDurationDays = (int)((MenuItem)sender).Tag;
        _settings.Save();
        RenderSensor();
        EvaluateSensor();
    }

    private static string Plural(int count, string unit) => count == 1 ? $"1 {unit}" : $"{count} {unit}s";

    /// <summary>One line for the menu: "Sensor ends in about 6 days (Fri 23 Oct)".</summary>
    private static string SensorSummary(SensorInfo sensor, DateTimeOffset now, int durationDays)
    {
        var ends = SensorSchedule.EndsAt(sensor, durationDays).ToLocalTime();
        var date = ends.ToString("ddd d MMM", CultureInfo.CurrentCulture);
        var left = SensorSchedule.Remaining(sensor, now, durationDays);

        if (left <= TimeSpan.Zero) return $"Sensor due to have ended ({date})";
        if (left < TimeSpan.FromDays(1)) return $"Sensor ends in about {Plural(Math.Max(1, (int)Math.Round(left.TotalHours)), "hour")}";
        return $"Sensor ends in about {Plural((int)Math.Round(left.TotalDays), "day")} ({date})";
    }

    /// <summary>The hover message on the unit and age text, in the system date and time format.</summary>
    private static string SensorDetail(SensorInfo sensor, DateTimeOffset now, int durationDays)
    {
        var ends = Stamp(SensorSchedule.EndsAt(sensor, durationDays));
        var left = SensorSchedule.Remaining(sensor, now, durationDays);
        var line = left <= TimeSpan.Zero ? $"Due to have ended about {ends}." : $"Ends about {ends}.";
        return $"Sensor started {Stamp(sensor.ActivatedAt)}.\n{line}";
    }

    private void RenderSensor() =>
        InfoStack.ToolTip = CurrentSensor is { } sensor ? SensorDetail(sensor, DateTimeOffset.UtcNow, SensorDuration) : null;

    // ---- insulin ---------------------------------------------------------------

    private void EvaluateInsulin()
    {
        var now = DateTimeOffset.UtcNow;
        var raised = _insulinReminder.Evaluate(_settings.Insulin, now, TimeZoneInfo.Local, _alerts.SnoozedUntil(now));
        if (raised is not null)
        {
            _tray.Notify("Insulin reminder", $"Due at {raised.Slot:HH:mm}. Not marked as administered yet.");
            if (_settings.Alerts.Sound) System.Media.SystemSounds.Exclamation.Play();
        }

        RenderInsulin();
    }

    /// <summary>Date and time in the format of the user's Windows region settings, for the syringe's tooltip.</summary>
    private static string Stamp(DateTimeOffset moment)
    {
        var local = moment.ToLocalTime();
        return $"{local.ToString("d", CultureInfo.CurrentCulture)} {local.ToString("t", CultureInfo.CurrentCulture)}";
    }

    /// <summary>The syringe: grey before the dose is due, amber with ! once due, green with a tick once marked.</summary>
    private void RenderInsulin()
    {
        var insulin = _settings.Insulin;
        var visibility = insulin.Enabled ? Visibility.Visible : Visibility.Collapsed;
        if (InsulinButton.Visibility != visibility)
        {
            InsulinButton.Visibility = visibility;
            ApplyLayoutScale(); // the layout leaves room for the icon
        }

        if (!insulin.Enabled) return;

        var status = InsulinSchedule.Status(insulin, DateTimeOffset.UtcNow, TimeZoneInfo.Local);
        var theme = Palette.Current;
        var next = Stamp(InsulinSchedule.NextSlotAfter(insulin, status.Slot, TimeZoneInfo.Local));

        switch (status.State)
        {
            case DoseState.Administered:
                SyringePath.Stroke = Palette.Brush(theme.InRange);
                InsulinBadge.Background = Palette.Brush(theme.InRange);
                InsulinBadgeText.Text = "✓";
                InsulinBadge.Visibility = Visibility.Visible;
                InsulinButton.ToolTip = $"Insulin administered on {Stamp(status.AdministeredAt!.Value)}.\nNext dose at {next}.";
                break;

            case DoseState.Due:
                SyringePath.Stroke = Palette.Brush(theme.High);
                InsulinBadge.Background = Palette.Brush(theme.High);
                InsulinBadgeText.Text = "!";
                InsulinBadge.Visibility = Visibility.Visible;
                InsulinButton.ToolTip = $"Insulin due since {Stamp(status.Slot)}, not administered yet.\nNext dose at {next}.";
                break;

            default:
                SyringePath.Stroke = Palette.Brush(theme.Muted);
                InsulinBadge.Visibility = Visibility.Collapsed;
                InsulinButton.ToolTip = $"Insulin not administered yet.\nNext dose at {Stamp(status.Slot)}.";
                break;
        }
    }

    /// <summary>Double-clicking the value fetches a new reading now, instead of waiting for the next minute.</summary>
    private void Value_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount != 2) return; // a single press falls through to the window, which drags it
        e.Handled = true;
        RefreshNow();
    }

    private void RefreshNow()
    {
        // A fake reading has nothing to refresh. The monitor itself refuses refreshes that come too soon or too often
        // (see GlucoseMonitor.RefreshNow), so repeated clicks cannot hammer the unofficial service; they are ignored.
        if (_monitor is null || _simulation is not null || !_monitor.RefreshNow()) return;

        _updatingUntil = DateTimeOffset.UtcNow.AddSeconds(15);
        RenderAge();
    }

    // Like the close button, this acts on the press: DragMove would swallow the button-up.
    private void Insulin_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        ToggleInsulin();
    }

    private void InsulinMenu_Click(object sender, RoutedEventArgs e) => ToggleInsulin();

    /// <summary>Turns the reminder off. The last "administered" time is forgotten too, so nothing about it stays saved.</summary>
    private void InsulinOff_Click(object sender, RoutedEventArgs e)
    {
        _settings.Insulin = _settings.Insulin with { Enabled = false, LastAdministeredAt = null };
        _settings.Save();
        _insulinReminder.Reset();
        EvaluateInsulin();
    }

    /// <summary>Marks the current dose as administered, or removes the mark. Both ask first: a wrong "administered" would hide a missed dose.</summary>
    private void ToggleInsulin()
    {
        var status = InsulinSchedule.Status(_settings.Insulin, DateTimeOffset.UtcNow, TimeZoneInfo.Local);

        if (status.State == DoseState.Administered)
        {
            var undo = MessageBox.Show(this,
                $"Remove the \"administered\" mark?\n\nInsulin administered on {Stamp(status.AdministeredAt ?? status.Slot)}.\nOnly do this if you did not administer it.",
                "Insulin", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No);
            if (undo != MessageBoxResult.Yes) return;

            _settings.Insulin = _settings.Insulin.Undo();
        }
        else
        {
            var mark = MessageBox.Show(this,
                $"Mark the {Stamp(status.Slot)} insulin dose as administered?",
                "Insulin", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No);
            if (mark != MessageBoxResult.Yes) return;

            _settings.Insulin = _settings.Insulin.MarkAdministered(DateTimeOffset.UtcNow);
        }

        _settings.Save();
        EvaluateInsulin();
    }

    private bool TestAlert(bool sound)
    {
        var shown = _tray.Notify("Test alert", "This is how an alert will look.");
        if (sound) System.Media.SystemSounds.Exclamation.Play();
        return shown;
    }

    private void Snooze_Click(object sender, RoutedEventArgs e)
    {
        var minutes = int.Parse((string)((MenuItem)sender).Tag);
        _alerts.Snooze(DateTimeOffset.UtcNow.AddMinutes(minutes));
    }

    private void Resume_Click(object sender, RoutedEventArgs e)
    {
        _alerts.Resume();
        EvaluateAlerts();
        EvaluateInsulin();
    }

    private void RenderValue()
    {
        UnitText.Text = _settings.Unit.Label();

        if (_last?.Snapshot.Current is { } now)
        {
            ValueText.Text = GlucoseUnits.Format(now.MgPerDl, _settings.Unit, CultureInfo.CurrentCulture);
            ArrowText.Text = now.Trend.ToArrow();
        }
        else
        {
            ValueText.Text = "--";
            ArrowText.Text = string.Empty;
        }
    }

    // ---- appearance ------------------------------------------------------------------------

    private void ApplyTheme()
    {
        var theme = _settings.Theme switch
        {
            ThemeChoice.Light => Theme.Light,
            ThemeChoice.Dark => Theme.Dark,
            _ => SystemUsesLightTheme() ? Theme.Light : Theme.Dark,
        };

        Palette.Use(theme);
        Resources["CardBackgroundBrush"] = Palette.Brush(theme.CardBackground);
        Resources["CardBorderBrush"] = Palette.Brush(theme.CardBorder);
        Resources["TextBrush"] = Palette.Brush(theme.Text);
        Resources["MutedBrush"] = Palette.Brush(theme.Muted);

        RenderValue();
        RenderAge();
        UpdateAlertBorder(DateTimeOffset.UtcNow); // the alert colours come from the theme
        RenderInsulin();
        Graph.Refresh();
    }

    private static bool SystemUsesLightTheme()
    {
        try
        {
            return Registry.GetValue(
                @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "AppsUseLightTheme", 1) is not 0;
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or IOException)
        {
            return false;
        }
    }

    // Raised on a background thread when the user changes Windows colour settings.
    private void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (_settings.Theme != ThemeChoice.System) return;
        if (e.Category is UserPreferenceCategory.General or UserPreferenceCategory.Color)
        {
            Dispatcher.BeginInvoke(ApplyTheme);
        }
    }

    private void OnFailed(Exception ex, bool fatal)
    {
        _updatingUntil = DateTimeOffset.MinValue;
        // Once the service is known to have changed, keep saying so rather than going back to "reconnecting".
        _problem = _serviceChanged ? "service changed" : fatal ? "sign-in needed" : "reconnecting";
        _problemIsFatal = fatal || _serviceChanged;
        RenderAge();
    }

    /// <summary>
    /// LibreLinkUp has kept answering in a way this version does not understand. Retrying will not fix that, so
    /// say it plainly and point to where a newer version would be published.
    /// </summary>
    private void OnServiceChanged(ServiceChangedException ex)
    {
        _serviceChanged = true;
        _problem = "service changed";
        _problemIsFatal = true;
        RenderAge();

        _tray.Notify(
            "Can't read LibreLinkUp",
            "Abbott may have changed or blocked the service. Click here to look for a newer version of Libre Monitor Desktop.",
            OpenReleasesPage);
    }

    private static void OpenReleasesPage() =>
        Process.Start(new ProcessStartInfo(AppInfo.ReleasesUrl) { UseShellExecute = true });

    private void Updates_Click(object sender, RoutedEventArgs e) => OpenReleasesPage();

    private static string FormatAge(TimeSpan age) =>
        age.TotalMinutes < 1 ? "just now" : $"{(int)age.TotalMinutes} min ago";

    private void RenderAge()
    {
        RenderAgeCore();
        RenderSensor();
        ApplyLayoutScale(); // the age text changes width ("just now" to "12 min ago"), which matters when the header fills the card
    }

    private void RenderAgeCore()
    {
        var current = _last?.Snapshot.Current;
        var age = current is null ? (TimeSpan?)null : DateTimeOffset.UtcNow - current.TimestampUtc;
        var stale = age > StaleAfter;

        _tray.Update(current, _settings.Unit, stale, _problem, age is { } a0 ? FormatAge(a0) : string.Empty, simulated: _simulation is not null);

        if (current is not null)
        {
            var colour = stale ? Palette.Muted : Palette.ForMgPerDl(current.MgPerDl);
            ValueText.Foreground = Palette.Brush(colour);
            ArrowText.Foreground = Palette.Brush(colour);
            ValueText.Opacity = stale ? 0.5 : 1;
        }
        else
        {
            ValueText.Foreground = Palette.Brush(Palette.Muted);
        }

        if (_simulation is not null)
        {
            // Make it impossible to mistake a fake value for a real one.
            AgeText.Text = "SIMULATED";
            AgeText.Foreground = Palette.Brush(Palette.High);
            return;
        }

        if (DateTimeOffset.UtcNow < _updatingUntil)
        {
            AgeText.Text = "updating…";
            AgeText.Foreground = Palette.Brush(Palette.Muted);
            return;
        }

        if (_problem is not null)
        {
            // The value on screen is getting old while the service cannot be reached: say how old.
            AgeText.Text = _problem == "reconnecting" && age is { TotalMinutes: >= 2 } old
                ? $"not updating · {FormatAge(old)}"
                : _problem;
            AgeText.Foreground = Palette.Brush(_problemIsFatal ? Palette.Low : Palette.High);
            return;
        }

        AgeText.Text = age is { } a ? FormatAge(a) : _last is null ? "connecting" : "no reading";
        AgeText.Foreground = Palette.Brush(stale ? Palette.High : Palette.Muted);
    }

    // ---- placement -------------------------------------------------------------------------

    private void ApplyPosition()
    {
        if (_settings is { Left: { } left, Top: { } top } && IsOnScreen(left, top))
        {
            Left = left;
            Top = top;
            return;
        }

        Snap("BottomRight");
    }

    private bool IsOnScreen(double left, double top) =>
        left >= SystemParameters.VirtualScreenLeft - 20
        && top >= SystemParameters.VirtualScreenTop - 20
        && left + Width <= SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth + 20
        && top + Height <= SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight + 20;

    private void Snap(string corner)
    {
        var area = SystemParameters.WorkArea;
        Left = corner.EndsWith("Left") ? area.Left + ScreenInset : area.Right - Width - ScreenInset;
        Top = corner.StartsWith("Top") ? area.Top + ScreenInset : area.Bottom - Height - ScreenInset;
        RememberPosition();
    }

    private void RememberPosition()
    {
        _settings.Left = Left;
        _settings.Top = Top;

        // Each mode (graph shown or hidden) remembers its own size.
        if (_settings.ShowGraph)
        {
            _settings.Width = Width;
            _settings.Height = Height;
        }
        else
        {
            _settings.CompactWidth = Width;
            _settings.CompactHeight = Height;
        }

        _settings.Save();
    }

    // ---- graph on / off --------------------------------------------------------------------

    private const double CompactDefaultWidth = 260;
    private const double CompactDefaultHeight = 132;

    private (double? Width, double? Height) SizeForCurrentMode() =>
        _settings.ShowGraph ? (_settings.Width, _settings.Height) : (_settings.CompactWidth, _settings.CompactHeight);

    /// <summary>Shows or hides the graph. Without it the header takes the whole card and can be made much smaller.</summary>
    private void ApplyGraphMode()
    {
        var show = _settings.ShowGraph;

        Graph.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        HeaderRow.Height = show ? GridLength.Auto : new GridLength(1, GridUnitType.Star);
        GraphRow.Height = show ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
        MinWidth = show ? 224 : 190;  // below this the unit and age text become unreadably small
        MinHeight = show ? 148 : 100;

        ApplyLayoutScale();
    }

    private void Graph_Click(object sender, RoutedEventArgs e)
    {
        RememberPosition(); // keeps the size of the mode being left, so switching back restores it

        _settings.ShowGraph = GraphItem.IsChecked;
        ApplyGraphMode();

        var (width, height) = SizeForCurrentMode();
        Width = Math.Clamp(width ?? (_settings.ShowGraph ? 304 : CompactDefaultWidth), MinWidth, MaxWidth);
        Height = Math.Clamp(height ?? (_settings.ShowGraph ? 196 : CompactDefaultHeight), MinHeight, MaxHeight);

        RememberPosition();
    }

    // ---- resizing --------------------------------------------------------------------------

    // The design is laid out for the default size; text grows and shrinks with the card.
    private const double DefaultCardWidth = 280;
    private const double DefaultCardHeight = 172;

    private void Window_SizeChanged(object sender, SizeChangedEventArgs e) => ApplyLayoutScale();

    private enum HeaderArrangement
    {
        /// <summary>Value and arrow on the left, unit and age on the right. Used with the graph, and on a wide, short card.</summary>
        SideBySide,

        /// <summary>Value and arrow, with the unit and age on one line underneath. Lets the value grow on a small card.</summary>
        Stacked,
    }

    /// <summary>
    /// The syringe sits beside the unit and age lines, or, when those are stacked under the value, right of the arrow
    /// (as on the Mac), so it does not end up on the unit line.
    /// </summary>
    private void PlaceInsulinButton(bool besideArrow)
    {
        var target = besideArrow ? ValueStack : InfoBlock;
        if (InsulinButton.Parent == target) return;

        ((Panel)InsulinButton.Parent).Children.Remove(InsulinButton);
        target.Children.Insert(besideArrow ? target.Children.Count : 0, InsulinButton);
    }

    private void ArrangeHeader(HeaderArrangement arrangement)
    {
        PlaceInsulinButton(arrangement == HeaderArrangement.Stacked);

        if (arrangement == HeaderArrangement.Stacked)
        {
            Grid.SetRow(InfoBlock, 1);
            ValueStack.HorizontalAlignment = HorizontalAlignment.Center;
            InfoBlock.HorizontalAlignment = HorizontalAlignment.Center;
            InfoStack.Orientation = Orientation.Horizontal;
            UnitText.HorizontalAlignment = HorizontalAlignment.Left;
            AgeText.HorizontalAlignment = HorizontalAlignment.Left;
        }
        else
        {
            Grid.SetRow(InfoBlock, 0);
            ValueStack.HorizontalAlignment = HorizontalAlignment.Left;
            InfoBlock.HorizontalAlignment = HorizontalAlignment.Right;
            InfoStack.Orientation = Orientation.Vertical;
            UnitText.HorizontalAlignment = HorizontalAlignment.Right;
            AgeText.HorizontalAlignment = HorizontalAlignment.Right;
        }
    }

    private void SetHeaderFonts(double valueScale, double infoScale)
    {
        ValueText.FontSize = 46 * valueScale;
        ArrowText.FontSize = 30 * valueScale;
        UnitText.FontSize = 11 * infoScale;
        AgeText.FontSize = 11 * infoScale;

        // The gaps scale with the text as well. Fixed pixel gaps look right at the default size but make a large
        // value crowd its arrow, and the unit run into the age text.
        ArrowText.Margin = new Thickness((_settings.ShowGraph ? 8 : 12) * valueScale, 0, 0, 0);

        var stacked = InfoStack.Orientation == Orientation.Horizontal;
        UnitText.Margin = stacked ? new Thickness(0, 0, 7 * infoScale, 0) : new Thickness(0);
        if (!_settings.ShowGraph)
        {
            // Space between the value and the line under it (the right-hand margin is only used with the graph).
            InfoBlock.Margin = stacked ? new Thickness(0, 6 * infoScale, 0, 0) : new Thickness(0);
        }

        // A fixed width, as wide as the longest normal age text. Otherwise "just now" becoming "1 min ago" changes the
        // width of this block, and everything beside it moves or resizes.
        // The syringe is sized with the text: beside the unit and age lines it is centred on them, and beside the
        // arrow (stacked layout) it is a little smaller and sits at the arrow's side.
        var besideArrow = stacked;
        InsulinButton.Width = InsulinButton.Height = 26 * (besideArrow
            ? Math.Clamp(valueScale, 0.6, 2)
            : Math.Clamp(valueScale, 0.85, _settings.ShowGraph ? 1.7 : 4));
        InsulinButton.Margin = besideArrow
            ? new Thickness(11.5 * valueScale, 0, 0, 0) // the same visible gap as between the value and the arrow
            : new Thickness(0, 0, 8 * infoScale, 0);

        // A fixed width for the text, as wide as the longest normal age text. Otherwise "just now" becoming "1 min ago"
        // changes the width of this block, and everything beside it moves or resizes.
        var age = TextWidth("59 min ago", AgeText.FontSize);
        var unit = TextWidth("mmol/L", UnitText.FontSize);
        // Stacked, the line is centred under the row, so it needs no fixed width: one would push the text off centre.
        InfoStack.MinWidth = stacked ? 0 : Math.Max(age, unit);
    }

    private double TextWidth(string text, double fontSize)
    {
        var typeface = new Typeface(AgeText.FontFamily, AgeText.FontStyle, AgeText.FontWeight, AgeText.FontStretch);
        return new FormattedText(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, typeface, fontSize,
            Brushes.Black, VisualTreeHelper.GetDpi(this).PixelsPerDip).WidthIncludingTrailingWhitespace;
    }

    /// <summary>Natural size of the header, at base font sizes, in the given arrangement.</summary>
    private Size MeasureHeader(HeaderArrangement arrangement)
    {
        ArrangeHeader(arrangement);
        SetHeaderFonts(1, 1);
        return CurrentHeaderSize(arrangement);
    }

    /// <summary>Size the header wants right now, at whatever font sizes are applied.</summary>
    private Size CurrentHeaderSize(HeaderArrangement arrangement)
    {
        var unbounded = new Size(double.PositiveInfinity, double.PositiveInfinity);
        ValueStack.Measure(unbounded);
        InfoBlock.Measure(unbounded);

        return arrangement == HeaderArrangement.Stacked
            ? new Size(
                Math.Max(ValueStack.DesiredSize.Width, InfoBlock.DesiredSize.Width),
                ValueStack.DesiredSize.Height + InfoBlock.DesiredSize.Height)
            : new Size(
                ValueStack.DesiredSize.Width + InfoBlock.DesiredSize.Width + 24,
                Math.Max(ValueStack.DesiredSize.Height, InfoBlock.DesiredSize.Height));
    }

    /// <summary>
    /// With the graph shown the text scales with the card as a whole. With the graph hidden the header fills the card:
    /// both arrangements are measured and the one that lets the value grow larger is used, so a small card is not
    /// left mostly empty beside a small value.
    /// </summary>
    private void ApplyLayoutScale()
    {
        if (_settings.ShowGraph)
        {
            var scale = Math.Clamp(Math.Min((ActualWidth - 24) / DefaultCardWidth, (ActualHeight - 24) / DefaultCardHeight), 0.75, 2.4);
            var small = Math.Clamp(scale, 1, 1.7);

            ContentGrid.Margin = new Thickness(16, 10, 16, 6); // the same on both sides, matching the graph
            ArrangeHeader(HeaderArrangement.SideBySide);
            SetHeaderFonts(scale, small);
            InfoBlock.Margin = new Thickness(0);
            return;
        }

        // The close-button margin is dropped here: it does not scale with the text, so keeping it would make
        // the value and the info block collide in narrow cards. The card padding is also tighter, to give the value room.
        ContentGrid.Margin = new Thickness(10, 6, 10, 6);
        InfoBlock.Margin = new Thickness(0);

        var availableWidth = ActualWidth - 24 - 2 - 20; // shadow margin, the card's border, then its own padding
        var availableHeight = ActualHeight - 24 - 2 - 12;

        double Fit(Size natural) =>
            natural.Width <= 0 || natural.Height <= 0
                ? 1
                : Math.Clamp(Math.Min(availableWidth / natural.Width, availableHeight / natural.Height), 0.3, 8);

        var sideBySide = Fit(MeasureHeader(HeaderArrangement.SideBySide));
        var stacked = Fit(MeasureHeader(HeaderArrangement.Stacked));

        var useStacked = stacked > sideBySide;
        ArrangeHeader(useStacked ? HeaderArrangement.Stacked : HeaderArrangement.SideBySide);
        var fit = useStacked ? stacked : sideBySide;
        SetHeaderFonts(fit, fit);

        // Not everything scales in step with the text (the syringe has size limits, the gaps are rounded), so check the
        // result and shrink a little if it still does not fit. Otherwise the last item in the row is cut off.
        var actual = CurrentHeaderSize(useStacked ? HeaderArrangement.Stacked : HeaderArrangement.SideBySide);
        var over = Math.Max(actual.Width / availableWidth, actual.Height / availableHeight);
        if (over > 1)
        {
            fit = Math.Max(fit / over, 0.3);
            SetHeaderFonts(fit, fit);
        }
    }

    private void Resize_DragDelta(object sender, DragDeltaEventArgs e)
    {
        var edge = (string)((Thumb)sender).Tag;

        if (edge.Contains('R')) Width = Math.Clamp(Width + e.HorizontalChange, MinWidth, MaxWidth);
        if (edge.Contains('B')) Height = Math.Clamp(Height + e.VerticalChange, MinHeight, MaxHeight);

        if (edge.Contains('L'))
        {
            var width = Math.Clamp(Width - e.HorizontalChange, MinWidth, MaxWidth);
            Left += Width - width; // keep the right edge fixed
            Width = width;
        }

        if (edge.Contains('T'))
        {
            var height = Math.Clamp(Height - e.VerticalChange, MinHeight, MaxHeight);
            Top += Height - height; // keep the bottom edge fixed
            Height = height;
        }
    }

    private void Resize_DragCompleted(object sender, DragCompletedEventArgs e) => RememberPosition();

    // ---- interaction -----------------------------------------------------------------------

    private void Window_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState != MouseButtonState.Pressed) return;
        DragMove(); // returns when the button is released
        RememberPosition();
    }

    // DragMove swallows the button-up, so the close button acts on the press instead.
    // With the tray icon shown it hides the widget there; without one it would strand the app, so it exits.
    private void Close_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (_tray.Visible) Hide();
        else Close();
    }

    // The menu belongs to the card; the close button must not show it.
    private void Close_ContextMenuOpening(object sender, ContextMenuEventArgs e) => e.Handled = true;

    private void Window_MouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (!_settings.ShowGraph) return; // the range only affects the graph

        var index = Array.IndexOf(RangeChoices, (int)Graph.Hours);
        index = Math.Clamp(index + (e.Delta > 0 ? -1 : 1), 0, RangeChoices.Length - 1);
        SetRange(RangeChoices[index]);
    }

    private void Window_MouseEnter(object sender, MouseEventArgs e) => CloseButton.Opacity = 0.8;

    private void Window_MouseLeave(object sender, MouseEventArgs e) => CloseButton.Opacity = 0;

    private void SetRange(int hours)
    {
        Graph.Hours = hours;
        _settings.Hours = hours;
        _settings.Save();
    }

    private void Menu_Opened(object sender, RoutedEventArgs e)
    {
        Range3.IsChecked = (int)Graph.Hours == 3;
        Range6.IsChecked = (int)Graph.Hours == 6;
        Range12.IsChecked = (int)Graph.Hours == 12;
        GraphItem.IsChecked = _settings.ShowGraph;
        RangeMenu.IsEnabled = _settings.ShowGraph; // the range only affects the graph
        TopmostItem.IsChecked = Topmost;
        foreach (var (item, index) in _simulationItems)
        {
            item.IsChecked = index < 0 ? _simulation is null : _simulation == Simulation.Scenarios[index];
        }

        var sensor = CurrentSensor;
        SensorItem.Visibility = SensorDurationMenu.Visibility = SensorSeparator.Visibility =
            sensor is null ? Visibility.Collapsed : Visibility.Visible;
        if (sensor is not null) SensorItem.Header = SensorSummary(sensor, DateTimeOffset.UtcNow, SensorDuration);
        foreach (var item in _sensorDurationItems) item.IsChecked = (int)item.Tag == SensorDuration;

        InsulinItem.Visibility = InsulinOffItem.Visibility = _settings.Insulin.Enabled ? Visibility.Visible : Visibility.Collapsed;
        InsulinSetupItem.Visibility = _settings.Insulin.Enabled ? Visibility.Collapsed : Visibility.Visible;
        InsulinItem.Header = InsulinSchedule.Status(_settings.Insulin, DateTimeOffset.UtcNow, TimeZoneInfo.Local).State == DoseState.Administered
            ? "Insulin: undo \"administered\""
            : "Insulin: mark as administered";

        var snoozedUntil = _alerts.SnoozedUntil(DateTimeOffset.UtcNow);
        ResumeItem.IsEnabled = snoozedUntil is not null;
        SnoozeMenu.Header = snoozedUntil is { } until
            ? $"Snooze alerts (until {until.ToLocalTime():HH:mm})"
            : "Snooze alerts";

        TrayItem.IsChecked = _settings.ShowTrayIcon;
        HideItem.IsEnabled = _settings.ShowTrayIcon; // hiding the widget without a tray icon would leave no way to bring it back
        UnitMg.IsChecked = _settings.Unit == GlucoseUnit.MgPerDl;
        UnitMmol.IsChecked = _settings.Unit == GlucoseUnit.MmolPerL;
        ThemeSystem.IsChecked = _settings.Theme == ThemeChoice.System;
        ThemeLight.IsChecked = _settings.Theme == ThemeChoice.Light;
        ThemeDark.IsChecked = _settings.Theme == ThemeChoice.Dark;
    }

    private void Unit_Click(object sender, RoutedEventArgs e)
    {
        _settings.Unit = Enum.Parse<GlucoseUnit>((string)((MenuItem)sender).Tag);
        _settings.Save();
        Graph.Unit = _settings.Unit;
        RenderValue();
        RenderAge(); // refreshes the tray icon, which shows the value in the chosen unit
    }

    private void TrayIcon_Click(object sender, RoutedEventArgs e)
    {
        _settings.ShowTrayIcon = TrayItem.IsChecked;
        _tray.Visible = _settings.ShowTrayIcon;
        _settings.Save();
    }

    private void HideToTray_Click(object sender, RoutedEventArgs e) => ToggleWidget();

    // The widget is only ever hidden while the tray icon is there to bring it back.
    private void ToggleWidget()
    {
        if (IsVisible)
        {
            if (_tray.Visible) Hide();
            return;
        }

        Show();
        Activate();
    }

    private void Theme_Click(object sender, RoutedEventArgs e)
    {
        _settings.Theme = Enum.Parse<ThemeChoice>((string)((MenuItem)sender).Tag);
        _settings.Save();
        ApplyTheme();
    }

    // ---- developer: simulated readings -----------------------------------------------------

    private void BuildSimulationMenu()
    {
        var root = new MenuItem { Header = "Developer: simulate reading" };

        var real = new MenuItem { Header = "Use real data" };
        real.Click += (_, _) => Simulate(-1);
        root.Items.Add(real);
        _simulationItems.Add((real, -1));
        root.Items.Add(new Separator());

        for (var i = 0; i < Simulation.Scenarios.Count; i++)
        {
            var index = i;
            var item = new MenuItem { Header = Simulation.Scenarios[i].Name };
            item.Click += (_, _) => Simulate(index);
            root.Items.Add(item);
            _simulationItems.Add((item, index));
        }

        // Just above the separator that precedes About / Sign out / Exit.
        Menu.Items.Insert(Menu.Items.Count - 4, root);
    }

    private void Simulate(int index)
    {
        _simulation = index < 0 ? null : Simulation.Scenarios[index];

        if (_simulation is not null) ShowSimulation();
        else if (_lastReal is not null) OnUpdated(_lastReal);
        else
        {
            _last = null;
            Graph.Readings = [];
            RenderValue();
            RenderAge();
        }
    }

    private void ShowSimulation()
    {
        var now = DateTimeOffset.UtcNow;
        var fake = new Patient("simulated", "Simulated", "data");
        OnUpdated(new MonitorUpdate(fake, Simulation.Build(_simulation!, now), now));
    }

    private void Range_Click(object sender, RoutedEventArgs e) => SetRange(int.Parse((string)((MenuItem)sender).Tag));

    private void Corner_Click(object sender, RoutedEventArgs e) => Snap((string)((MenuItem)sender).Tag);

    private void Topmost_Click(object sender, RoutedEventArgs e)
    {
        Topmost = TopmostItem.IsChecked;
        _settings.Topmost = Topmost;
        _settings.Save();
    }

    private void About_Click(object sender, RoutedEventArgs e) => MessageBox.Show(
        $"Libre Monitor Desktop {typeof(MainWindow).Assembly.GetName().Version?.ToString(3)}\n\n"
        + "Libre Monitor Desktop shows glucose data that the LibreLink app has already uploaded, read through LibreLinkUp. It never talks to the sensor and never changes any data.\n\n"
        + "Nothing about your glucose readings is saved on this PC. The only things stored are your login (encrypted, and readable only by your Windows user) "
        + "and your preferences, such as units, theme, window position, alert limits and the insulin reminder (its times, and when you last marked a dose as administered).\n\n"
        + "It is not a medical device and is not affiliated with Abbott. Do not use it for treatment decisions.",
        "About Libre Monitor Desktop", MessageBoxButton.OK, MessageBoxImage.Information);

    private void Exit_Click(object sender, RoutedEventArgs e) => Close();

    private async void SignOut_Click(object sender, RoutedEventArgs e)
    {
        if (_monitor is not null) await _monitor.StopAsync();
        _store.Clear();
        Close();
    }
}
