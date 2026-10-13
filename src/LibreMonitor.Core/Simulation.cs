namespace LibreMonitor.Core;

/// <summary>A fake state for testing how the display looks. Developer use only.</summary>
public sealed record SimulationScenario(string Name, double? MgPerDl, Trend Trend = Trend.Stable, bool Stale = false);

/// <summary>Builds synthetic readings so every colour state can be seen without waiting for real glucose to change.</summary>
public static class Simulation
{
    // The edges (69/70, 180/181) sit either side of the colour thresholds.
    public static IReadOnlyList<SimulationScenario> Scenarios { get; } =
    [
        new("Low 55 (red)", 55, Trend.DownSlow),
        new("Low 69, just under range (red)", 69, Trend.DownSlow),
        new("In range 100 (green)", 100),
        new("In range 180, top of range (green)", 180),
        new("High 181, just over range (amber)", 181, Trend.UpSlow),
        new("High 250 (amber)", 250, Trend.UpSlow),
        new("Very high 350 (amber)", 350, Trend.UpFast),
        new("Old reading (grey)", 110, Trend.Stable, Stale: true),
        new("No reading", null),
    ];

    private const int HistorySteps = 48; // 12 hours at the API's 15 minute spacing
    private const int StaleMinutes = 25; // comfortably past the 10 minute "old reading" limit

    /// <summary>A believable 12 hour history that eases from a gentle wave into the scenario's value.</summary>
    public static GlucoseSnapshot Build(SimulationScenario scenario, DateTimeOffset now)
    {
        if (scenario.MgPerDl is not { } target) return new GlucoseSnapshot(null, []);

        var latest = scenario.Stale ? now.AddMinutes(-StaleMinutes) : now;
        var history = new List<GlucoseReading>(HistorySteps);

        for (var i = 0; i < HistorySteps; i++)
        {
            var progress = i / (double)(HistorySteps - 1);
            var ease = Math.Clamp((progress - 0.6) / 0.4, 0, 1);
            ease = ease * ease * (3 - 2 * ease); // smoothstep

            var baseline = 115 + 25 * Math.Sin(i / 5.0);
            var value = Math.Round(baseline + (target - baseline) * ease);
            history.Add(Reading(latest.AddMinutes(-15 * (HistorySteps - i)), value, Trend.Unknown));
        }

        return new GlucoseSnapshot(Reading(latest, target, scenario.Trend), history);
    }

    private static GlucoseReading Reading(DateTimeOffset at, double mgPerDl, Trend trend) =>
        new(at, mgPerDl, mgPerDl, trend, IsHigh: mgPerDl > 180, IsLow: mgPerDl < 70);
}
