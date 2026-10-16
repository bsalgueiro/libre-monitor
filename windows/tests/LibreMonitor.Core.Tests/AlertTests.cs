using LibreMonitor.Core;

namespace LibreMonitor.Core.Tests;

public class AlertTests
{
    private static readonly DateTimeOffset T0 = new(2026, 10, 14, 12, 0, 0, TimeSpan.Zero);
    private static readonly AlertSettings Both = new(LowEnabled: true, HighEnabled: true, RepeatMinutes: 30);

    private static GlucoseReading Reading(double mgPerDl, DateTimeOffset at) =>
        new(at, mgPerDl, mgPerDl, Trend.Stable, mgPerDl > 180, mgPerDl < 70);

    /// <summary>Evaluate a fresh reading taken at the given minute.</summary>
    private static AlertRaised? Step(AlertEvaluator e, AlertSettings s, double mgPerDl, int minute) =>
        e.Evaluate(s, Reading(mgPerDl, T0.AddMinutes(minute)), T0.AddMinutes(minute));

    // ---- raising -----------------------------------------------------------------------------

    [Fact]
    public void InRange_RaisesNothing() => Assert.Null(Step(new AlertEvaluator(), Both, 100, 0));

    [Fact]
    public void Low_RaisesOnce_OnEntry()
    {
        var e = new AlertEvaluator();

        var raised = Step(e, Both, 65, 0);

        Assert.Equal(AlertKind.Low, raised!.Kind);
        Assert.False(raised.IsReminder);
        Assert.Equal(65, raised.Reading.MgPerDl);
        Assert.Null(Step(e, Both, 64, 1));
        Assert.Null(Step(e, Both, 63, 2));
    }

    [Fact]
    public void High_RaisesOnce_OnEntry()
    {
        var e = new AlertEvaluator();

        Assert.Equal(AlertKind.High, Step(e, Both, 200, 0)!.Kind);
        Assert.Null(Step(e, Both, 210, 1));
    }

    [Fact]
    public void Thresholds_AreStrict_SoTheValueOnTheLineIsInRange()
    {
        var e = new AlertEvaluator();

        Assert.Null(Step(e, Both, 70, 0));
        Assert.Null(Step(e, Both, 180, 1));
        Assert.NotNull(Step(e, Both, 69, 2));
    }

    [Fact]
    public void DisabledKinds_NeverRaise()
    {
        var onlyHigh = new AlertSettings(LowEnabled: false, HighEnabled: true);

        Assert.Null(Step(new AlertEvaluator(), onlyHigh, 40, 0));
        Assert.NotNull(Step(new AlertEvaluator(), onlyHigh, 250, 0));
    }

    [Fact]
    public void CustomThresholds_AreUsed()
    {
        var strict = new AlertSettings(LowEnabled: true, LowMgPerDl: 90, HighEnabled: true, HighMgPerDl: 140);

        Assert.Equal(AlertKind.Low, Step(new AlertEvaluator(), strict, 85, 0)!.Kind);
        Assert.Equal(AlertKind.High, Step(new AlertEvaluator(), strict, 150, 0)!.Kind);
        Assert.Null(Step(new AlertEvaluator(), strict, 100, 0));
    }

    // ---- reminders ---------------------------------------------------------------------------

    [Fact]
    public void StillOutOfRange_RemindsAfterTheInterval_ThenKeepsReminding()
    {
        var e = new AlertEvaluator();
        Step(e, Both, 60, 0);

        Assert.Null(Step(e, Both, 60, 29));
        var reminder = Step(e, Both, 60, 30);
        Assert.True(reminder!.IsReminder);
        Assert.Null(Step(e, Both, 60, 59));
        Assert.NotNull(Step(e, Both, 60, 60));
    }

    [Fact]
    public void RepeatZero_AlertsOncePerEpisode()
    {
        var once = Both with { RepeatMinutes = 0 };
        var e = new AlertEvaluator();
        Assert.NotNull(Step(e, once, 60, 0));

        Assert.Null(Step(e, once, 60, 30));
        Assert.Null(Step(e, once, 60, 600));
    }

    // ---- episodes and flapping ---------------------------------------------------------------

    [Fact]
    public void BackInRange_ThenOutAgain_IsANewEpisode()
    {
        var e = new AlertEvaluator();
        Assert.NotNull(Step(e, Both, 65, 0));

        Assert.Null(Step(e, Both, 100, 5)); // recovered, well clear of the line
        var again = Step(e, Both, 65, 10);

        Assert.NotNull(again);
        Assert.False(again.IsReminder);
    }

    [Fact]
    public void HoveringOnTheLine_DoesNotAlertEveryCrossing()
    {
        var e = new AlertEvaluator();
        Assert.NotNull(Step(e, Both, 69, 0));

        Assert.Null(Step(e, Both, 71, 1)); // back over the line but inside the 5 mg/dL margin
        Assert.Null(Step(e, Both, 69, 2)); // same episode, so no new alert
        Assert.Null(Step(e, Both, 71, 3));
        Assert.Null(Step(e, Both, 69, 4));
    }

    [Fact]
    public void ClearingTheMargin_ReArms()
    {
        var e = new AlertEvaluator();
        Step(e, Both, 69, 0);

        Step(e, Both, 75, 1); // exactly threshold + margin counts as clear
        Assert.NotNull(Step(e, Both, 69, 2));
    }

    [Fact]
    public void HighReArms_BelowTheThresholdByTheMargin()
    {
        var e = new AlertEvaluator();
        Step(e, Both, 190, 0);

        Assert.Null(Step(e, Both, 178, 1)); // in range but within the margin
        Assert.Null(Step(e, Both, 190, 2));
        Step(e, Both, 175, 3);
        Assert.NotNull(Step(e, Both, 190, 4));
    }

    [Fact]
    public void SwitchingFromHighToLow_RaisesTheNewKind()
    {
        var e = new AlertEvaluator();
        Step(e, Both, 200, 0);

        var raised = Step(e, Both, 60, 5);

        Assert.Equal(AlertKind.Low, raised!.Kind);
        Assert.False(raised.IsReminder);
    }

    // ---- old data ----------------------------------------------------------------------------

    [Fact]
    public void OldReading_IsIgnored()
    {
        var e = new AlertEvaluator();
        var old = Reading(55, T0);

        Assert.Null(e.Evaluate(Both, old, T0.AddMinutes(11)));
    }

    [Fact]
    public void OldReading_DoesNotEndAnEpisode()
    {
        var e = new AlertEvaluator();
        Step(e, Both, 60, 0);

        e.Evaluate(Both, Reading(110, T0.AddMinutes(1)), T0.AddMinutes(20)); // far too old to trust
        Assert.Null(Step(e, Both, 60, 21)); // still the same episode: no fresh alert
    }

    [Fact]
    public void NoReading_RaisesNothing() => Assert.Null(new AlertEvaluator().Evaluate(Both, null, T0));

    // ---- snooze ------------------------------------------------------------------------------

    [Fact]
    public void Snooze_SuppressesAlerts_ThenRaisesIfStillOut()
    {
        var e = new AlertEvaluator();
        e.Snooze(T0.AddMinutes(30));

        Assert.Null(Step(e, Both, 60, 0));
        Assert.Null(Step(e, Both, 60, 29));
        var raised = Step(e, Both, 60, 31);

        Assert.NotNull(raised); // the episode was never announced, so it is not a reminder
        Assert.False(raised.IsReminder);
    }

    [Fact]
    public void Snooze_ThatEndsAfterRecovery_RaisesNothing()
    {
        var e = new AlertEvaluator();
        e.Snooze(T0.AddMinutes(30));
        Step(e, Both, 60, 0);
        Step(e, Both, 100, 10);

        Assert.Null(Step(e, Both, 100, 31));
    }

    [Fact]
    public void Resume_CancelsASnooze()
    {
        var e = new AlertEvaluator();
        e.Snooze(T0.AddHours(2));
        e.Resume();

        Assert.NotNull(Step(e, Both, 60, 0));
        Assert.Null(e.SnoozedUntil(T0));
    }

    [Fact]
    public void SnoozedUntil_ReportsOnlyWhileActive()
    {
        var e = new AlertEvaluator();
        e.Snooze(T0.AddMinutes(30));

        Assert.Equal(T0.AddMinutes(30), e.SnoozedUntil(T0.AddMinutes(10)));
        Assert.Null(e.SnoozedUntil(T0.AddMinutes(31)));
    }

    // ---- settings changes --------------------------------------------------------------------

    [Fact]
    public void Reset_StartsAFreshEpisode()
    {
        var e = new AlertEvaluator();
        Step(e, Both, 60, 0);
        e.Reset();

        Assert.NotNull(Step(e, Both, 60, 1));
    }

    [Fact]
    public void TurningTheAlertOff_EndsItsEpisode()
    {
        var e = new AlertEvaluator();
        Step(e, Both, 60, 0);

        var off = Both with { LowEnabled = false };
        Assert.Null(Step(e, off, 60, 1));
        Assert.NotNull(Step(e, Both, 60, 2)); // turned back on: counts as new
    }

    // ---- classification (drives the widget highlight) ----------------------------------------

    [Theory]
    [InlineData(65, AlertKind.Low)]
    [InlineData(100, null)]
    [InlineData(200, AlertKind.High)]
    public void Classify_IgnoresHistoryAndSnooze(double mgPerDl, AlertKind? expected)
    {
        var e = new AlertEvaluator();
        e.Snooze(T0.AddHours(1));

        Assert.Equal(expected, AlertEvaluator.Classify(Both, Reading(mgPerDl, T0), T0));
    }

    [Fact]
    public void Classify_OldReading_IsNull() =>
        Assert.Null(AlertEvaluator.Classify(Both, Reading(50, T0), T0.AddMinutes(11)));

    // ---- validation --------------------------------------------------------------------------

    [Fact]
    public void Defaults_AreOff_AndValid()
    {
        var defaults = new AlertSettings();

        Assert.False(defaults.LowEnabled);
        Assert.False(defaults.HighEnabled);
        Assert.Equal(70, defaults.LowMgPerDl);
        Assert.Equal(180, defaults.HighMgPerDl);
        Assert.Null(defaults.Validate());
    }

    [Theory]
    [InlineData(30, 180, 30)]   // low too small
    [InlineData(160, 180, 30)]  // low too large
    [InlineData(70, 90, 30)]    // high too small
    [InlineData(70, 450, 30)]   // high too large
    [InlineData(150, 120, 30)]  // low above high
    [InlineData(70, 180, -1)]   // negative repeat
    [InlineData(70, 180, 241)]  // repeat too long
    public void Validate_RejectsUnusableSettings(double low, double high, int repeat) =>
        Assert.NotNull(new AlertSettings(LowMgPerDl: low, HighMgPerDl: high, RepeatMinutes: repeat).Validate());

    [Theory]
    [InlineData(40, 400, 0)]
    [InlineData(150, 151, 240)]
    [InlineData(70, 180, 30)]
    public void Validate_AcceptsTheLimits(double low, double high, int repeat) =>
        Assert.Null(new AlertSettings(LowMgPerDl: low, HighMgPerDl: high, RepeatMinutes: repeat).Validate());
}
