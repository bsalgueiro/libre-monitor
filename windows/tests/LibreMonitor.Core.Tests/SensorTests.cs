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
