using LibreMonitor.Core;

namespace LibreMonitor.Core.Tests;

public class SensorTests
{
    private static readonly DateTimeOffset Activated = new(2026, 10, 9, 13, 4, 0, TimeSpan.Zero);
    private static readonly SensorInfo Sensor = new(Activated);

    [Fact]
    public void EndsAt_IsFourteenDaysAfterActivation()
    {
        Assert.Equal(new DateTimeOffset(2026, 10, 23, 13, 4, 0, TimeSpan.Zero), SensorSchedule.EndsAt(Sensor));
    }

    [Fact]
    public void Remaining_CountsDown_AndGoesNegativeAfterTheEnd()
    {
        Assert.Equal(TimeSpan.FromDays(6), SensorSchedule.Remaining(Sensor, Activated.AddDays(8)));
        Assert.True(SensorSchedule.Remaining(Sensor, Activated.AddDays(15)) < TimeSpan.Zero);
    }

    // ---- duration ----

    [Fact]
    public void EndsAt_UsesTheChosenDuration()
    {
        Assert.Equal(Activated.AddDays(15), SensorSchedule.EndsAt(Sensor, 15));
        Assert.Equal(Activated.AddDays(14), SensorSchedule.EndsAt(Sensor, 14));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(13)]
    [InlineData(16)]
    [InlineData(-5)]
    public void AnUnknownDuration_FallsBackToFourteenDays(int days)
    {
        Assert.Equal(SensorSchedule.DefaultDurationDays, SensorSchedule.NormalizeDurationDays(days));
        Assert.Equal(Activated.AddDays(14), SensorSchedule.EndsAt(Sensor, days));
    }

    [Fact]
    public void TheChoices_IncludeTheDefault_AndOnlyHoldSensibleValues()
    {
        Assert.Contains(SensorSchedule.DefaultDurationDays, SensorSchedule.DurationChoices);
        foreach (var days in SensorSchedule.DurationChoices) Assert.InRange(days, 10, 20);
    }

    private static readonly SensorAlertSettings Default = new(); // on, 1 day before, once a day

    private static SensorEndingRaised? Check(SensorExpiryEvaluator e, DateTimeOffset now, SensorAlertSettings? settings = null,
        DateTimeOffset? snoozedUntil = null, int durationDays = 14, SensorInfo? sensor = null) =>
        e.Evaluate(sensor ?? Sensor, now, settings ?? Default, snoozedUntil, durationDays);

    [Fact]
    public void ALongerDuration_MovesTheNoticeLater()
    {
        var e = new SensorExpiryEvaluator();

        Assert.Null(Check(e, Activated.AddDays(13), durationDays: 15));
        Assert.NotNull(Check(e, Activated.AddDays(14), durationDays: 15));
    }

    [Fact]
    public void ChangingTheDuration_AllowsANewNotice()
    {
        var e = new SensorExpiryEvaluator();
        Assert.NotNull(Check(e, Activated.AddDays(13), durationDays: 14));
        Assert.Null(Check(e, Activated.AddDays(13).AddHours(1), durationDays: 14));

        // Switched to 15 days: that notice came a day early, so another is due when 15 days are nearly up.
        Assert.Null(Check(e, Activated.AddDays(13).AddHours(2), durationDays: 15));
        Assert.NotNull(Check(e, Activated.AddDays(14), durationDays: 15));
    }

    // ---- alert settings ----

    [Fact]
    public void Defaults_AreOnOneDayBeforeOnceADay_AndValid()
    {
        Assert.True(Default.Enabled);
        Assert.Equal(1, Default.DaysBefore);
        Assert.Equal(1440, Default.RepeatMinutes);
        Assert.Null(Default.Validate());
    }

    [Theory]
    [InlineData(0)]
    [InlineData(8)]
    [InlineData(-1)]
    public void DaysBefore_MustBeBetweenOneAndSeven(int days) => Assert.NotNull(new SensorAlertSettings(DaysBefore: days).Validate());

    [Theory]
    [InlineData(1)]
    [InlineData(7)]
    public void DaysBefore_AcceptsTheLimits(int days) => Assert.Null(new SensorAlertSettings(DaysBefore: days).Validate());

    [Theory]
    [InlineData(0)]
    [InlineData(30)]
    [InlineData(720)]
    public void Repeat_MustBeOneOfTheChoices(int minutes) => Assert.NotNull(new SensorAlertSettings(RepeatMinutes: minutes).Validate());

    [Fact]
    public void TheRepeatChoices_AreOnceADay_SixHours_AndEveryHour() =>
        Assert.Equal(new[] { 1440, 360, 60 }, SensorAlertSettings.RepeatChoices);

    // ---- notification ----

    [Fact]
    public void NoNotice_WhileMoreThanTheLeadTimeRemains()
    {
        Assert.Null(Check(new SensorExpiryEvaluator(), Activated.AddDays(8)));
        Assert.Null(Check(new SensorExpiryEvaluator(), Activated.AddDays(13).AddMinutes(-1)));
        Assert.Null(Check(new SensorExpiryEvaluator(), Activated.AddDays(10).AddMinutes(-1), new SensorAlertSettings(DaysBefore: 3)));
    }

    [Fact]
    public void Notice_ComesWhenTheLeadTimeIsReached()
    {
        var raised = Check(new SensorExpiryEvaluator(), Activated.AddDays(13));
        Assert.Equal(SensorSchedule.EndsAt(Sensor), raised!.EndsAt);
        Assert.False(raised.IsReminder);

        Assert.NotNull(Check(new SensorExpiryEvaluator(), Activated.AddDays(11), new SensorAlertSettings(DaysBefore: 3)));
        Assert.NotNull(Check(new SensorExpiryEvaluator(), Activated.AddDays(7), new SensorAlertSettings(DaysBefore: 7)));
    }

    [Fact]
    public void OnceADay_RepeatsEveryDayUntilTheEnd()
    {
        var e = new SensorExpiryEvaluator();
        var threeDays = new SensorAlertSettings(DaysBefore: 3, RepeatMinutes: 1440);

        Assert.False(Check(e, Activated.AddDays(11), threeDays)!.IsReminder);
        Assert.Null(Check(e, Activated.AddDays(11).AddHours(23), threeDays));
        Assert.True(Check(e, Activated.AddDays(12), threeDays)!.IsReminder);
        Assert.True(Check(e, Activated.AddDays(13), threeDays)!.IsReminder);
        Assert.Null(Check(e, Activated.AddDays(14), threeDays)); // the sensor has ended
    }

    [Fact]
    public void EverySixHours_AndEveryHour_Repeat()
    {
        var sixHours = new SensorEndingTest(360);
        Assert.NotNull(sixHours.At(0));
        Assert.Null(sixHours.At(5));
        Assert.NotNull(sixHours.At(6));
        Assert.NotNull(sixHours.At(12));

        var hourly = new SensorEndingTest(60);
        Assert.NotNull(hourly.At(0));
        Assert.Null(hourly.At(0.5));
        Assert.NotNull(hourly.At(1));
        Assert.NotNull(hourly.At(2));
    }

    /// <summary>A helper that follows one evaluator with the sensor's last day, in hours after the lead time was reached.</summary>
    private sealed class SensorEndingTest(int repeatMinutes)
    {
        private readonly SensorExpiryEvaluator _e = new();
        private readonly SensorAlertSettings _settings = new(DaysBefore: 1, RepeatMinutes: repeatMinutes);

        public SensorEndingRaised? At(double hours) => _e.Evaluate(Sensor, Activated.AddDays(13).AddHours(hours), _settings);
    }

    [Fact]
    public void NoNotice_OnceTheSensorHasEnded()
    {
        Assert.Null(Check(new SensorExpiryEvaluator(), Activated.AddDays(14)));
        Assert.Null(Check(new SensorExpiryEvaluator(), Activated.AddDays(16)));
    }

    [Fact]
    public void NoNotice_WithoutASensor() => Assert.Null(new SensorExpiryEvaluator().Evaluate(null, Activated.AddDays(13), Default));

    [Fact]
    public void NoNotice_WhenTurnedOff_AndTurningItOnStartsFresh()
    {
        var e = new SensorExpiryEvaluator();
        var off = new SensorAlertSettings(Enabled: false);

        Assert.Null(Check(e, Activated.AddDays(13), off));
        Assert.False(Check(e, Activated.AddDays(13).AddHours(1))!.IsReminder);
    }

    [Fact]
    public void ANewSensor_GetsItsOwnNotices()
    {
        var e = new SensorExpiryEvaluator();
        Assert.NotNull(Check(e, Activated.AddDays(13)));

        var next = new SensorInfo(Activated.AddDays(14));

        Assert.Null(Check(e, Activated.AddDays(20), sensor: next));
        Assert.False(Check(e, Activated.AddDays(27), sensor: next)!.IsReminder);
    }

    [Fact]
    public void Snooze_HoldsTheNotice_ThenRaisesItWhenItEnds()
    {
        var e = new SensorExpiryEvaluator();
        var until = Activated.AddDays(13).AddHours(2);

        Assert.Null(Check(e, Activated.AddDays(13), snoozedUntil: until));
        Assert.Null(Check(e, Activated.AddDays(13).AddHours(1), snoozedUntil: until));

        var raised = Check(e, until, snoozedUntil: until);
        Assert.NotNull(raised);
        Assert.False(raised!.IsReminder);
    }

    [Fact]
    public void APauseWithoutAnEnd_HoldsTheNoticeIndefinitely()
    {
        var e = new SensorExpiryEvaluator();

        Assert.Null(Check(e, Activated.AddDays(13), snoozedUntil: DateTimeOffset.MaxValue));
        Assert.Null(Check(e, Activated.AddDays(13).AddHours(20), snoozedUntil: DateTimeOffset.MaxValue));
        Assert.NotNull(Check(e, Activated.AddDays(13).AddHours(21)));
    }

    [Fact]
    public void Reset_StartsAFreshEpisode()
    {
        var e = new SensorExpiryEvaluator();
        Assert.NotNull(Check(e, Activated.AddDays(13)));

        e.Reset();

        Assert.False(Check(e, Activated.AddDays(13).AddMinutes(1))!.IsReminder);
    }
}
