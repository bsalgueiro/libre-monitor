using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using LibreMonitor.Core;

namespace LibreMonitor.App;

/// <summary>
/// Edits the alert thresholds in the unit the widget displays. Values are converted to mg/dL for storage.
/// </summary>
public partial class AlertsWindow : Window
{
    private readonly AlertSettings _original;
    private readonly GlucoseUnit _unit;
    private readonly Func<bool, bool> _sendTest;
    private readonly string _lowShown;
    private readonly string _highShown;

    public AlertSettings? Result { get; private set; }

    /// <param name="sendTest">Shows a sample notification (and plays the sound if the argument is true); returns whether a notification could be shown.</param>
    public AlertsWindow(AlertSettings current, GlucoseUnit unit, Func<bool, bool> sendTest)
    {
        InitializeComponent();
        _original = current;
        _unit = unit;
        _sendTest = sendTest;

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
    }

    private string Show(double mgPerDl) => GlucoseUnits.Format(mgPerDl, _unit, CultureInfo.CurrentCulture);

    private void ApplyTheme()
    {
        var theme = Palette.Current;
        Background = Palette.Brush(Color.FromRgb(theme.CardBackground.R, theme.CardBackground.G, theme.CardBackground.B));
        Foreground = Palette.Brush(theme.Text);

        // CheckBox sets its own text colour instead of inheriting the window's, which left dark labels on the dark card.
        LowBox.Foreground = HighBox.Foreground = SoundBox.Foreground = Palette.Brush(theme.Text);
        DisclaimerText.Foreground = Palette.Brush(theme.Muted);
        InfoText.Foreground = Palette.Brush(theme.Muted);
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

        Result = settings;
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
