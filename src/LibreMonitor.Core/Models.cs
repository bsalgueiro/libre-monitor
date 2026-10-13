namespace LibreMonitor.Core;

/// <summary>Trend arrow as reported by LibreView (1 = falling fast ... 5 = rising fast).</summary>
public enum Trend
{
    Unknown = 0,
    DownFast = 1,
    DownSlow = 2,
    Stable = 3,
    UpSlow = 4,
    UpFast = 5,
}

public static class TrendExtensions
{
    public static string ToArrow(this Trend trend) => trend switch
    {
        Trend.DownFast => "↓",
        Trend.DownSlow => "↘",
        Trend.Stable => "→",
        Trend.UpSlow => "↗",
        Trend.UpFast => "↑",
        _ => "?",
    };
}

public enum GlucoseUnit
{
    MgPerDl,
    MmolPerL,
}

public static class GlucoseUnits
{
    /// <summary>mg/dL per mmol/L for glucose (molar mass 180.16 g/mol; the conventional factor is 18.0182).</summary>
    public const double MgPerDlPerMmolPerL = 18.0182;

    public static string Label(this GlucoseUnit unit) => unit == GlucoseUnit.MmolPerL ? "mmol/L" : "mg/dL";

    /// <summary>Formats a value stored in mg/dL: whole numbers for mg/dL, one decimal for mmol/L.</summary>
    public static string Format(double mgPerDl, GlucoseUnit unit, IFormatProvider? provider = null) => unit == GlucoseUnit.MmolPerL
        ? (mgPerDl / MgPerDlPerMmolPerL).ToString("0.0", provider)
        : mgPerDl.ToString("0", provider);
}

/// <summary>One glucose measurement. <see cref="MgPerDl"/> is always mg/dL; <see cref="Value"/> is in the account's display unit.</summary>
public sealed record GlucoseReading(
    DateTimeOffset TimestampUtc,
    double MgPerDl,
    double Value,
    Trend Trend,
    bool IsHigh,
    bool IsLow);

/// <summary>A person whose data the logged-in follower account can see.</summary>
public sealed record Patient(string PatientId, string FirstName, string LastName);

/// <summary>Latest reading plus the recent history returned by the graph endpoint.</summary>
public sealed record GlucoseSnapshot(GlucoseReading? Current, IReadOnlyList<GlucoseReading> History);

public sealed class LibreLinkUpOptions
{
    /// <summary>Global entry point. Login may redirect to a regional host.</summary>
    public string BaseUrl { get; init; } = "https://api.libreview.io";

    /// <summary>The follower API rejects clients below a minimum version, so this needs to track the official app.</summary>
    public string AppVersion { get; init; } = "4.16.0";

    public string Product { get; init; } = "llu.android";

    /// <summary>
    /// Required: the service's edge layer answers 403 to requests that carry no User-Agent.
    /// It identifies this tool honestly rather than imitating a browser or the official app.
    /// </summary>
    public string UserAgent { get; init; } = "LibreMonitor/0.1 (personal read-only monitor)";
}
