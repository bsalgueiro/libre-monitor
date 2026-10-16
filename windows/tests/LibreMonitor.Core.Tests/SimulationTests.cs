using LibreMonitor.Core;

namespace LibreMonitor.Core.Tests;

public class SimulationTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 14, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void Scenarios_CoverEveryColourStateAndBothThresholdEdges()
    {
        var values = Simulation.Scenarios.Where(s => s.MgPerDl.HasValue && !s.Stale).Select(s => s.MgPerDl!.Value).ToList();

        Assert.Contains(values, v => v < 70);
        Assert.Contains(values, v => v is >= 70 and <= 180);
        Assert.Contains(values, v => v > 180);
        Assert.Contains(69.0, values);
        Assert.Contains(180.0, values);
        Assert.Contains(181.0, values);
        Assert.Contains(Simulation.Scenarios, s => s.Stale);
        Assert.Contains(Simulation.Scenarios, s => s.MgPerDl is null);
    }

    [Fact]
    public void Build_CurrentMatchesTheScenario_AndIsNow()
    {
        var scenario = new SimulationScenario("t", 250, Trend.UpSlow);

        var snapshot = Simulation.Build(scenario, Now);

        Assert.Equal(250, snapshot.Current!.MgPerDl);
        Assert.Equal(Trend.UpSlow, snapshot.Current.Trend);
        Assert.Equal(Now, snapshot.Current.TimestampUtc);
        Assert.True(snapshot.Current.IsHigh);
        Assert.False(snapshot.Current.IsLow);
    }

    [Fact]
    public void Build_HistoryIsOrdered_EndsNearTheTarget_AndStaysBeforeCurrent()
    {
        var snapshot = Simulation.Build(new SimulationScenario("t", 55, Trend.DownSlow), Now);

        Assert.Equal(48, snapshot.History.Count);
        Assert.Equal(snapshot.History.OrderBy(r => r.TimestampUtc), snapshot.History);
        Assert.True(snapshot.History[^1].TimestampUtc < snapshot.Current!.TimestampUtc);
        Assert.Equal(55, snapshot.History[^1].MgPerDl, precision: 0);
    }

    [Fact]
    public void Build_StaleScenario_IsOlderThanTheOldReadingLimit()
    {
        var snapshot = Simulation.Build(new SimulationScenario("t", 110, Stale: true), Now);

        Assert.True(Now - snapshot.Current!.TimestampUtc > TimeSpan.FromMinutes(10));
    }

    [Fact]
    public void Build_NoReading_HasNothing()
    {
        var snapshot = Simulation.Build(new SimulationScenario("t", null), Now);

        Assert.Null(snapshot.Current);
        Assert.Empty(snapshot.History);
    }
}
