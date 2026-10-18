using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using LibreMonitor.Core;

namespace LibreMonitor.App;

/// <summary>Widget preferences kept next to the (separately encrypted) credentials. Nothing here is sensitive.</summary>
public sealed class WidgetSettings
{
    private static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LibreMonitor", "settings.json");

    public double? Left { get; set; }
    public double? Top { get; set; }
    /// <summary>Size with the graph shown (also the size kept while the graph is hidden, so it can be restored).</summary>
    public double? Width { get; set; }
    public double? Height { get; set; }

    /// <summary>Size with the graph hidden. Each mode remembers its own, so toggling the graph is reversible.</summary>
    public double? CompactWidth { get; set; }
    public double? CompactHeight { get; set; }

    public bool ShowGraph { get; set; } = true;
    public int Hours { get; set; } = 6;
    public bool Topmost { get; set; } = true;
    public bool ShowTrayIcon { get; set; } = true;

    /// <summary>Thresholds are stored in mg/dL whatever unit is displayed. Both alerts start switched off.</summary>
    public AlertSettings Alerts { get; set; } = new();

    /// <summary>The "sensor is about to end" alert: on or off, how many days before the end to start, and how often to repeat.</summary>
    public SensorAlertSettings SensorAlert { get; set; } = new();

    /// <summary>
    /// All alerts are paused until the user turns them back on (the same as a snooze with no end). Kept across restarts,
    /// so the widget stays quiet until it is switched back on; the menu says so while it is on.
    /// </summary>
    public bool AlertsPaused { get; set; }

    /// <summary>How many days the user's sensor lasts (a choice from <see cref="SensorSchedule.DurationChoices"/>), used to estimate when it ends.</summary>
    public int SensorDurationDays { get; set; } = SensorSchedule.DefaultDurationDays;

    /// <summary>
    /// The insulin reminder: its schedule and the time the dose was last marked as administered. That one
    /// timestamp is the only thing recorded about it (no amounts, no history). Off by default.
    /// </summary>
    public InsulinSettings Insulin { get; set; } = new();

    [JsonConverter(typeof(JsonStringEnumConverter))]
    public GlucoseUnit Unit { get; set; } = GlucoseUnit.MgPerDl;

    [JsonConverter(typeof(JsonStringEnumConverter))]
    public ThemeChoice Theme { get; set; } = ThemeChoice.Dark;

    public static WidgetSettings Load()
    {
        try
        {
            return File.Exists(FilePath)
                ? JsonSerializer.Deserialize<WidgetSettings>(File.ReadAllText(FilePath)) ?? new WidgetSettings()
                : new WidgetSettings();
        }
        catch (Exception ex) when (ex is JsonException or IOException)
        {
            return new WidgetSettings();
        }
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this));
        }
        catch (IOException)
        {
            // Preferences are a convenience; failing to save them must never disturb the monitor.
        }
    }
}
