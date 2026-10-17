namespace LibreMonitor.Core;

/// <summary>
/// When the sensor in use is due to end. The service reports when the sensor was activated but not when it ends, so the
/// end is the activation plus the sensor's duration. The service does not say how long that is either, so the user
/// chooses it (14 days by default; the Libre 2 Plus and Libre 3 Plus last 15). It is still an estimate, and wording
/// around it says "about".
/// </summary>
public static class SensorSchedule
{
    /// <summary>The duration assumed until the user chooses one.</summary>
    public const int DefaultDurationDays = 14;

    /// <summary>The durations the user can choose from. More can be added here when another kind of sensor needs it.</summary>
    public static readonly IReadOnlyList<int> DurationChoices = [14, 15];

    /// <summary>The notification about the sensor ending comes when this little time is left.</summary>
    public static readonly TimeSpan NoticeBefore = TimeSpan.FromHours(24);

    /// <returns>The given duration if it is one of the choices, otherwise the default (for example a saved value that no longer exists).</returns>
    public static int NormalizeDurationDays(int days) => DurationChoices.Contains(days) ? days : DefaultDurationDays;

    public static DateTimeOffset EndsAt(SensorInfo sensor, int durationDays = DefaultDurationDays) =>
        sensor.ActivatedAt + TimeSpan.FromDays(NormalizeDurationDays(durationDays));

    /// <summary>Time left; zero or negative once the sensor is due to have ended.</summary>
    public static TimeSpan Remaining(SensorInfo sensor, DateTimeOffset now, int durationDays = DefaultDurationDays) =>
        EndsAt(sensor, durationDays) - now;
}

/// <summary>A notification that the sensor is about to end.</summary>
public sealed record SensorEndingRaised(DateTimeOffset EndsAt);

/// <summary>
/// Decides when to say the sensor is about to end: once per sensor and chosen duration, when
/// <see cref="SensorSchedule.NoticeBefore"/> or less remains. Pure logic with no UI or clock of its own. Nothing is
/// stored, so after a restart the notice may come once more for the same sensor. Changing the duration counts as a
/// new question: a notice already given for 14 days does not stop one at the end of 15.
/// </summary>
public sealed class SensorExpiryEvaluator
{
    private (DateTimeOffset ActivatedAt, int DurationDays)? _notifiedFor;

    /// <param name="snoozedUntil">The shared alert snooze, if one is active; the notice is raised once the snooze ends.</param>
    public SensorEndingRaised? Evaluate(
        SensorInfo? sensor, DateTimeOffset now, DateTimeOffset? snoozedUntil = null, int durationDays = SensorSchedule.DefaultDurationDays)
    {
        if (sensor is null) return null;

        durationDays = SensorSchedule.NormalizeDurationDays(durationDays);
        var remaining = SensorSchedule.Remaining(sensor, now, durationDays);
        if (remaining <= TimeSpan.Zero || remaining > SensorSchedule.NoticeBefore) return null;
        if (_notifiedFor == (sensor.ActivatedAt, durationDays)) return null;
        if (snoozedUntil is { } until && now < until) return null;

        _notifiedFor = (sensor.ActivatedAt, durationDays);
        return new SensorEndingRaised(SensorSchedule.EndsAt(sensor, durationDays));
    }
}
