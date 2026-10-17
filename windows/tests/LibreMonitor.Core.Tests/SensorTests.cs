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

    [Fact]
    public void ALongerDuration_MovesTheNoticeLater()
    {
        var e = new SensorExpiryEvaluator();

        // With 15 days the sensor still has a day and an hour left at day 13 and a bit, so there is no notice yet.
        Assert.Null(e.Evaluate(Sensor, Activated.AddDays(13), durationDays: 15));
        Assert.NotNull(e.Evaluate(Sensor, Activated.AddDays(14), durationDays: 15));
    }

    [Fact]
    public void ChangingTheDuration_AllowsANewNotice()
    {
        var e = new SensorExpiryEvaluator();
        Assert.NotNull(e.Evaluate(Sensor, Activated.AddDays(13), durationDays: 14));
        Assert.Null(e.Evaluate(Sensor, Activated.AddDays(13).AddHours(1), durationDays: 14));

        // Switched to 15 days: that notice came a day early, so another is due when 15 days are nearly up.
        Assert.Null(e.Evaluate(Sensor, Activated.AddDays(13).AddHours(2), durationDays: 15));
        Assert.NotNull(e.Evaluate(Sensor, Activated.AddDays(14), durationDays: 15));
    }

    // ---- notification ----

    [Fact]
    public void NoNotice_WhileMoreThanADayRemains()
    {
        Assert.Null(new SensorExpiryEvaluator().Evaluate(Sensor, Activated.AddDays(8)));
        Assert.Null(new SensorExpiryEvaluator().Evaluate(Sensor, Activated.AddDays(13).AddMinutes(-1)));
    }

    [Fact]
    public void Notice_ComesOnce_WhenADayOrLessRemains()
    {
        var e = new SensorExpiryEvaluator();

        var raised = e.Evaluate(Sensor, Activated.AddDays(13));

        Assert.Equal(SensorSchedule.EndsAt(Sensor), raised!.EndsAt);
        Assert.Null(e.Evaluate(Sensor, Activated.AddDays(13).AddHours(2)));
        Assert.Null(e.Evaluate(Sensor, Activated.AddDays(13).AddHours(20)));
    }

    [Fact]
    public void NoNotice_OnceTheSensorHasEnded()
    {
        Assert.Null(new SensorExpiryEvaluator().Evaluate(Sensor, Activated.AddDays(14)));
        Assert.Null(new SensorExpiryEvaluator().Evaluate(Sensor, Activated.AddDays(16)));
    }

    [Fact]
    public void NoNotice_WithoutASensor() => Assert.Null(new SensorExpiryEvaluator().Evaluate(null, Activated.AddDays(13)));

    [Fact]
    public void ANewSensor_GetsItsOwnNotice()
    {
        var e = new SensorExpiryEvaluator();
        Assert.NotNull(e.Evaluate(Sensor, Activated.AddDays(13)));

        var next = new SensorInfo(Activated.AddDays(14));

        Assert.Null(e.Evaluate(next, Activated.AddDays(20)));
        Assert.NotNull(e.Evaluate(next, Activated.AddDays(27)));
    }

    [Fact]
    public void Snooze_HoldsTheNotice_ThenRaisesItWhenItEnds()
    {
        var e = new SensorExpiryEvaluator();
        var until = Activated.AddDays(13).AddHours(2);

        Assert.Null(e.Evaluate(Sensor, Activated.AddDays(13), until));
        Assert.Null(e.Evaluate(Sensor, Activated.AddDays(13).AddHours(1), until));
        Assert.NotNull(e.Evaluate(Sensor, until, until));
    }
}
