namespace LibreMonitor.Core;

/// <summary>
/// When the sensor in use is due to end. The service reports when the sensor was activated but not when it ends, so the
/// end is the activation plus the usual lifetime. That is an estimate: wording around it says "about", and a sensor
/// type with a longer life would simply end a day later than shown, which is the safe way round.
/// </summary>
public static class SensorSchedule
{
    /// <summary>Libre 2 and 3 sensors last 14 days (a Libre 3 Plus lasts 15).</summary>
    public static readonly TimeSpan Lifetime = TimeSpan.FromDays(14);

    /// <summary>The notification about the sensor ending comes when this little time is left.</summary>
    public static readonly TimeSpan NoticeBefore = TimeSpan.FromHours(24);

    public static DateTimeOffset EndsAt(SensorInfo sensor) => sensor.ActivatedAt + Lifetime;

    /// <summary>Time left; zero or negative once the sensor is due to have ended.</summary>
    public static TimeSpan Remaining(SensorInfo sensor, DateTimeOffset now) => EndsAt(sensor) - now;
}

/// <summary>A notification that the sensor is about to end.</summary>
public sealed record SensorEndingRaised(DateTimeOffset EndsAt);

/// <summary>
/// Decides when to say the sensor is about to end: once per sensor, when <see cref="SensorSchedule.NoticeBefore"/> or
/// less remains. Pure logic with no UI or clock of its own. Nothing is stored, so after a restart the notice may come
/// once more for the same sensor.
/// </summary>
public sealed class SensorExpiryEvaluator
{
    private DateTimeOffset? _notifiedFor;

    /// <param name="snoozedUntil">The shared alert snooze, if one is active; the notice is raised once the snooze ends.</param>
    public SensorEndingRaised? Evaluate(SensorInfo? sensor, DateTimeOffset now, DateTimeOffset? snoozedUntil = null)
    {
        if (sensor is null) return null;

        var remaining = SensorSchedule.Remaining(sensor, now);
        if (remaining <= TimeSpan.Zero || remaining > SensorSchedule.NoticeBefore) return null;
        if (_notifiedFor == sensor.ActivatedAt) return null;
        if (snoozedUntil is { } until && now < until) return null;

        _notifiedFor = sensor.ActivatedAt;
        return new SensorEndingRaised(SensorSchedule.EndsAt(sensor));
    }
}
