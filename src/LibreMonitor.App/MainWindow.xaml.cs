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
    private MonitorUpdate? _last;
    private MonitorUpdate? _lastReal;           // newest real update, kept while a simulation is showing
    private SimulationScenario? _simulation;    // developer branch: fake readings for checking colours
    private readonly List<(MenuItem Item, int Index)> _simulationItems = [];
    private string? _problem;
    private bool _problemIsFatal;

    public MainWindow()
    {
        InitializeComponent();
        _client = new LibreLinkUpClient(_http);

        _tray = new TrayController(() => IsVisible, ToggleWidget, Close) { Visible = _settings.ShowTrayIcon };

        Topmost = _settings.Topmost;
        Graph.Hours = RangeChoices.Contains(_settings.Hours) ? _settings.Hours : 6;
        Graph.Unit = _settings.Unit;
        ApplyTheme();
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
        if (_settings is { Width: { } width, Height: { } height })
        {
            Width = Math.Clamp(width, MinWidth, MaxWidth);
            Height = Math.Clamp(height, MinHeight, MaxHeight);
        }

        ApplyPosition();

        BuildSimulationMenu();

        // Developer shortcut: LibreMonitor.App.exe --simulate 2 starts with scenario number 2 already showing.
        var args = Environment.GetCommandLineArgs();
        var flag = Array.IndexOf(args, "--simulate");
        if (flag >= 0 && flag + 1 < args.Length
            && int.TryParse(args[flag + 1], out var scenario) && scenario >= 0 && scenario < Simulation.Scenarios.Count)
        {
            Simulate(scenario);
        }

        _tick.Tick += (_, _) =>
        {
            // A simulated reading is rebuilt each tick so it does not age into the grey "old reading" state.
            if (_simulation is not null) ShowSimulation();
            else { RenderAge(); Graph.Refresh(); }
        };
        _tick.Start();

        Loaded += async (_, _) => await StartAsync();
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
        _monitor.Start();
        await Task.CompletedTask;
    }

    private void OnUpdated(MonitorUpdate update)
    {
        _last = update;
        _problem = null;

        var readings = update.Snapshot.History.ToList();
        if (update.Snapshot.Current is { } current && (readings.Count == 0 || current.TimestampUtc > readings[^1].TimestampUtc))
        {
            readings.Add(current);
        }

        Graph.Readings = readings;
        RenderValue();
        RenderAge();
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
        _problem = fatal ? "sign-in needed" : "reconnecting";
        _problemIsFatal = fatal;
        RenderAge();
    }

    private static string FormatAge(TimeSpan age) =>
        age.TotalMinutes < 1 ? "just now" : $"{(int)age.TotalMinutes} min ago";

    private void RenderAge()
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

        if (_problem is not null)
        {
            AgeText.Text = _problem;
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
        _settings.Width = Width;
        _settings.Height = Height;
        _settings.Save();
    }

    // ---- resizing --------------------------------------------------------------------------

    // The design is laid out for the default size; text grows and shrinks with the card.
    private const double DefaultCardWidth = 280;
    private const double DefaultCardHeight = 172;

    private void Window_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var scale = Math.Clamp(Math.Min((ActualWidth - 24) / DefaultCardWidth, (ActualHeight - 24) / DefaultCardHeight), 0.75, 2.4);
        var small = Math.Clamp(scale, 1, 1.7);

        ValueText.FontSize = 46 * scale;
        ArrowText.FontSize = 30 * scale;
        UnitText.FontSize = 11 * small;
        AgeText.FontSize = 11 * small;
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
        TopmostItem.IsChecked = Topmost;
        foreach (var (item, index) in _simulationItems)
        {
            item.IsChecked = index < 0 ? _simulation is null : _simulation == Simulation.Scenarios[index];
        }

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
        "Libre Monitor shows glucose data that the LibreLink app has already uploaded, read through LibreLinkUp. It never talks to the sensor and never changes any data.\n\n"
        + "It is not a medical device and is not affiliated with Abbott. Do not use it for treatment decisions.",
        "About Libre Monitor", MessageBoxButton.OK, MessageBoxImage.Information);

    private void Exit_Click(object sender, RoutedEventArgs e) => Close();

    private async void SignOut_Click(object sender, RoutedEventArgs e)
    {
        if (_monitor is not null) await _monitor.StopAsync();
        _store.Clear();
        Close();
    }
}
