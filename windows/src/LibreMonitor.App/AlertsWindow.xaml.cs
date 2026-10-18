using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using LibreMonitor.Core;

namespace LibreMonitor.App;

/// <summary>
/// Edits every alert, one tab per kind (glucose, insulin, sensor), and the switch that pauses them all. Glucose
/// thresholds are edited in the unit the widget displays and converted to mg/dL for storage.
/// </summary>
public partial class AlertsWindow : Window
{
    private readonly AlertSettings _original;
    private readonly InsulinSettings _originalInsulin;
    private readonly GlucoseUnit _unit;
    private readonly Func<bool, bool> _sendTest;
    private readonly string _lowShown;
    private readonly string _highShown;

    public AlertSettings? Result { get; private set; }
    public InsulinSettings? InsulinResult { get; private set; }
    public SensorAlertSettings? SensorResult { get; private set; }

    private readonly Action<bool> _setPaused;
    private bool _loading = true;

    /// <param name="sendTest">Shows a sample notification (and plays the sound if the argument is true); returns whether a notification could be shown.</param>
    /// <param name="setPaused">
    /// Pauses or resumes all alerts in the app, straight away and not on Save. "Pause all alerts" here is the same setting
    /// as the pause and resume entries in the widget menu.
    /// </param>
    public AlertsWindow(
        AlertSettings current, InsulinSettings insulin, SensorAlertSettings sensor, bool paused, GlucoseUnit unit,
        Func<bool, bool> sendTest, Action<bool> setPaused)
    {
        InitializeComponent();
        _original = current;
        _originalInsulin = insulin;
        _unit = unit;
        _sendTest = sendTest;
        _setPaused = setPaused;

        ApplyTheme();

        LowBox.IsChecked = current.LowEnabled;
        HighBox.IsChecked = current.HighEnabled;
        SoundBox.IsChecked = current.Sound;
        LowUnit.Text = HighUnit.Text = unit.Label();

        // The text as first shown is remembered: a threshold left untouched keeps its exact stored value,
        // so opening and saving in mmol/L never nudges 70 mg/dL to 70.3 through rounding.
        _lowShown = LowValue.Text = Show(current.LowMgPerDl);
        _highShown = HighValue.Text = Show(current.HighMgPerDl);

        RepeatBox.SelectedItem = RepeatBox.Items.Cast<ComboBoxItem>()
            .MinBy(item => Math.Abs(int.Parse((string)item.Tag) - current.RepeatMinutes));

        InsulinBox.IsChecked = insulin.Enabled;
        DosesBox.SelectedIndex = insulin.DosesPerDay == 2 ? 1 : 0;
        FirstTime.Text = ShowTime(insulin.FirstDoseMinutes);
        SecondTime.Text = ShowTime(insulin.SecondDoseMinutes);
        InsulinRepeatBox.SelectedItem = InsulinRepeatBox.Items.Cast<ComboBoxItem>()
            .MinBy(item => Math.Abs(int.Parse((string)item.Tag) - insulin.RepeatMinutes));
        UpdateInsulinPanel();

        SensorBox.IsChecked = sensor.Enabled;
        SensorDaysBox.SelectedItem = SensorDaysBox.Items.Cast<ComboBoxItem>()
            .MinBy(item => Math.Abs(int.Parse((string)item.Tag) - sensor.DaysBefore));
        SensorRepeatBox.SelectedItem = SensorRepeatBox.Items.Cast<ComboBoxItem>()
            .MinBy(item => Math.Abs(int.Parse((string)item.Tag) - sensor.RepeatMinutes));
        UpdateSensorPanel();

        PauseBox.IsChecked = paused;
        UpdatePause();
        _loading = false;
    }

    private void Pause_Changed(object sender, RoutedEventArgs e)
    {
        UpdatePause();
        if (!_loading) _setPaused(PauseBox.IsChecked == true); // applied at once, like the menu entries
    }

    /// <summary>While everything is paused every other option is greyed out, until the box is unticked again.</summary>
    private void UpdatePause()
    {
        if (SoundBox is null || TestButton is null) return; // still loading

        var paused = PauseBox.IsChecked == true;
        foreach (var part in new FrameworkElement[] { GlucoseTab, InsulinTab, SensorTab, SoundBox, TestButton })
        {
            part.IsEnabled = !paused;
            part.Opacity = paused ? 0.45 : 1;
        }
    }

    private void Sensor_Changed(object sender, RoutedEventArgs e) => UpdateSensorPanel();

    private void UpdateSensorPanel()
    {
        if (SensorPanel is null) return; // still loading

        SensorPanel.IsEnabled = SensorBox.IsChecked == true;
        SensorPanel.Opacity = SensorPanel.IsEnabled ? 1 : 0.5;
    }

    private static string ShowTime(int minutes) => $"{minutes / 60:00}:{minutes % 60:00}";

    private static bool TryParseTime(string text, out int minutes)
    {
        minutes = 0;
        var parts = text.Trim().Split(':');
        if (parts.Length != 2
            || !int.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var hour)
            || !int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var minute)
            || hour > 23 || minute > 59)
        {
            return false;
        }

        minutes = hour * 60 + minute;
        return true;
    }

    private void Insulin_Changed(object sender, RoutedEventArgs e) => UpdateInsulinPanel();

    private void Doses_SelectionChanged(object sender, SelectionChangedEventArgs e) => UpdateInsulinPanel();

    private void UpdateInsulinPanel()
    {
        if (InsulinPanel is null || DosesBox.SelectedItem is null) return; // still loading

        var twice = ((ComboBoxItem)DosesBox.SelectedItem).Tag as string == "2";
        InsulinPanel.IsEnabled = InsulinBox.IsChecked == true;
        InsulinPanel.Opacity = InsulinPanel.IsEnabled ? 1 : 0.5;
        SecondRow.Visibility = twice ? Visibility.Visible : Visibility.Collapsed;
        FirstLabel.Text = twice ? "First time" : "Time";
    }

    private string Show(double mgPerDl) => GlucoseUnits.Format(mgPerDl, _unit, CultureInfo.CurrentCulture);

    private void ApplyTheme()
    {
        var theme = Palette.Current;
        Background = Palette.Brush(Color.FromRgb(theme.CardBackground.R, theme.CardBackground.G, theme.CardBackground.B));
        Foreground = Palette.Brush(theme.Text);

        // CheckBox sets its own text colour instead of inheriting the window's, which left dark labels on the dark card.
        LowBox.Foreground = HighBox.Foreground = SoundBox.Foreground = InsulinBox.Foreground =
            PauseBox.Foreground = SensorBox.Foreground = Palette.Brush(theme.Text);
        DisclaimerText.Foreground = InsulinDisclaimerText.Foreground = TimeHint.Foreground =
            PauseHint.Foreground = SensorNoteText.Foreground = Palette.Brush(theme.Muted);
        InfoText.Foreground = Palette.Brush(theme.Muted);

        // The tabs are drawn from these (see the styles in the XAML).
        Resources["TextBrush"] = Palette.Brush(theme.Text);
        Resources["MutedBrush"] = Palette.Brush(theme.Muted);
        Resources["AccentBrush"] = Palette.Brush(theme.InRange);
        Resources["LineBrush"] = Palette.Brush(Palette.WithAlpha(theme.Ink, 50));
    }

    private bool TryRead(TextBox box, string shown, double original, string name, out double mgPerDl)
    {
        mgPerDl = original;
        if (box.Text.Trim() == shown) return true; // untouched

        var text = box.Text.Trim();
        // Accept either decimal separator, whatever the Windows language, since people type both.
        if (!double.TryParse(text, NumberStyles.Float, CultureInfo.CurrentCulture, out var value)
            && !double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out value))
        {
            ShowError($"Enter a number for the {name} threshold.");
            return false;
        }

        mgPerDl = _unit == GlucoseUnit.MmolPerL ? Math.Round(value * GlucoseUnits.MgPerDlPerMmolPerL, 1) : value;
        return true;
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        if (!TryRead(LowValue, _lowShown, _original.LowMgPerDl, "low", out var low)) return;
        if (!TryRead(HighValue, _highShown, _original.HighMgPerDl, "high", out var high)) return;

        var repeat = int.Parse((string)((ComboBoxItem)RepeatBox.SelectedItem).Tag);
        var settings = new AlertSettings(
            LowEnabled: LowBox.IsChecked == true, LowMgPerDl: low,
            HighEnabled: HighBox.IsChecked == true, HighMgPerDl: high,
            RepeatMinutes: repeat, Sound: SoundBox.IsChecked == true);

        if (settings.Validate(_unit) is { } problem)
        {
            ShowError(problem);
            return;
        }

        // The "administered" mark is kept as it was: only the schedule is edited here.
        var insulin = _originalInsulin with
        {
            Enabled = InsulinBox.IsChecked == true,
            DosesPerDay = ((ComboBoxItem)DosesBox.SelectedItem).Tag as string == "2" ? 2 : 1,
            RepeatMinutes = int.Parse((string)((ComboBoxItem)InsulinRepeatBox.SelectedItem).Tag),
        };

        if (!TryParseTime(FirstTime.Text, out var first) || (insulin.DosesPerDay == 2 && !TryParseTime(SecondTime.Text, out _)))
        {
            ShowError("Enter each dose time as hours and minutes, like 08:00.");
            return;
        }

        TryParseTime(SecondTime.Text, out var second);
        insulin = insulin with { FirstDoseMinutes = first, SecondDoseMinutes = insulin.DosesPerDay == 2 ? second : _originalInsulin.SecondDoseMinutes };
        if (insulin.Enabled && insulin.Validate() is { } insulinProblem)
        {
            ShowError(insulinProblem);
            return;
        }

        var sensor = new SensorAlertSettings(
            Enabled: SensorBox.IsChecked == true,
            DaysBefore: int.Parse((string)((ComboBoxItem)SensorDaysBox.SelectedItem).Tag),
            RepeatMinutes: int.Parse((string)((ComboBoxItem)SensorRepeatBox.SelectedItem).Tag));
        if (sensor.Validate() is { } sensorProblem)
        {
            ShowError(sensorProblem);
            return;
        }

        Result = settings;
        InsulinResult = insulin;
        SensorResult = sensor;
        DialogResult = true;
    }

    private void Test_Click(object sender, RoutedEventArgs e)
    {
        ErrorText.Visibility = Visibility.Collapsed;
        var shown = _sendTest(SoundBox.IsChecked == true);
        InfoText.Text = shown
            ? "Test sent. If you saw nothing, Windows may be hiding notifications (check Focus assist or Do not disturb)."
            : "The tray icon is turned off, so notifications cannot be shown. Alerts will use the sound and the widget's coloured border instead.";
        InfoText.Visibility = Visibility.Visible;
    }

    private void ShowError(string message)
    {
        InfoText.Visibility = Visibility.Collapsed;
        ErrorText.Text = message;
        ErrorText.Visibility = Visibility.Visible;
    }
}
