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
    public double? Width { get; set; }
    public double? Height { get; set; }
    public int Hours { get; set; } = 6;
    public bool Topmost { get; set; } = true;
    public bool ShowTrayIcon { get; set; } = true;

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
