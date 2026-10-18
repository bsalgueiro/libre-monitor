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

    /// <returns>The given duration if it is one of the choices, otherwise the default (for example a saved value that no longer exists).</returns>
    public static int NormalizeDurationDays(int days) => DurationChoices.Contains(days) ? days : DefaultDurationDays;

    public static DateTimeOffset EndsAt(SensorInfo sensor, int durationDays = DefaultDurationDays) =>
        sensor.ActivatedAt + TimeSpan.FromDays(NormalizeDurationDays(durationDays));

    /// <summary>Time left; zero or negative once the sensor is due to have ended.</summary>
    public static TimeSpan Remaining(SensorInfo sensor, DateTimeOffset now, int durationDays = DefaultDurationDays) =>
        EndsAt(sensor, durationDays) - now;
}

/// <summary>
/// The user's choices for the "sensor is about to end" alert. On by default, one day before the end, once a day, which
/// is the single notice the app gave before this could be set.
/// </summary>
/// <param name="DaysBefore">How many days before the end the alerts start, 1 to <see cref="MaxDaysBefore"/>.</param>
/// <param name="RepeatMinutes">How often to repeat once they have started: one of <see cref="RepeatChoices"/>.</param>
public sealed record SensorAlertSettings(bool Enabled = true, int DaysBefore = 1, int RepeatMinutes = 1440)
{
    public const int MaxDaysBefore = 7;

    /// <summary>Once a day, every 6 hours, every hour (in minutes).</summary>
    public static readonly IReadOnlyList<int> RepeatChoices = [1440, 360, 60];

    /// <returns>A message describing the first problem, or null when the settings are usable.</returns>
    public string? Validate()
    {
        if (DaysBefore is < 1 or > MaxDaysBefore) return $"The sensor alert must start between 1 and {MaxDaysBefore} days before the end.";
        if (!RepeatChoices.Contains(RepeatMinutes)) return "Choose how often to repeat the sensor alert.";
        return null;
    }
}

/// <summary>A notification that the sensor is about to end.</summary>
public sealed record SensorEndingRaised(DateTimeOffset EndsAt, bool IsReminder = false);

/// <summary>
/// Decides when to say the sensor is about to end: from <see cref="SensorAlertSettings.DaysBefore"/> days before the
/// end, then again at the chosen interval, until the end. Pure logic with no UI or clock of its own. Nothing is stored,
/// so after a restart the first notice may come once more for the same sensor. Changing the duration counts as a new
/// question: notices given for 14 days do not stop the ones at the end of 15.
/// </summary>
public sealed class SensorExpiryEvaluator
{
    private (DateTimeOffset ActivatedAt, int DurationDays)? _episode;
    private DateTimeOffset? _lastRaisedAt;

    /// <summary>Forget what has been raised, for example after the settings change.</summary>
    public void Reset()
    {
        _episode = null;
        _lastRaisedAt = null;
    }

    /// <param name="snoozedUntil">The shared alert snooze, if one is active; a held notice is raised once it ends.</param>
    public SensorEndingRaised? Evaluate(
        SensorInfo? sensor, DateTimeOffset now, SensorAlertSettings settings, DateTimeOffset? snoozedUntil = null,
        int durationDays = SensorSchedule.DefaultDurationDays)
    {
        if (sensor is null || !settings.Enabled)
        {
            Reset();
            return null;
        }

        durationDays = SensorSchedule.NormalizeDurationDays(durationDays);
        var remaining = SensorSchedule.Remaining(sensor, now, durationDays);
        if (remaining <= TimeSpan.Zero || remaining > TimeSpan.FromDays(settings.DaysBefore)) return null;

        if (_episode != (sensor.ActivatedAt, durationDays))
        {
            _episode = (sensor.ActivatedAt, durationDays);
            _lastRaisedAt = null;
        }

        if (snoozedUntil is { } until && now < until) return null;

        var neverRaised = _lastRaisedAt is null;
        var reminderDue = _lastRaisedAt is { } last && now - last >= TimeSpan.FromMinutes(settings.RepeatMinutes);
        if (!neverRaised && !reminderDue) return null;

        _lastRaisedAt = now;
        return new SensorEndingRaised(SensorSchedule.EndsAt(sensor, durationDays), IsReminder: !neverRaised);
    }
}
