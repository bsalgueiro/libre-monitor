using System.Globalization;

namespace LibreMonitor.Core;

public enum AlertKind
{
    Low,
    High,
}

/// <summary>
/// User-chosen alert thresholds, always in mg/dL (the app converts for display). Both alerts are off by default.
/// </summary>
/// <param name="RepeatMinutes">Reminder interval while still out of range; 0 means alert once per episode.</param>
public sealed record AlertSettings(
    bool LowEnabled = false,
    double LowMgPerDl = 70,
    bool HighEnabled = false,
    double HighMgPerDl = 180,
    int RepeatMinutes = 30,
    bool Sound = true)
{
    public const double MinLow = 40, MaxLow = 150;
    public const double MinHigh = 100, MaxHigh = 400;
    public const int MaxRepeatMinutes = 240;

    /// <param name="unit">The unit the user is editing in; only used to word the message.</param>
    /// <returns>A message describing the first problem, or null when the settings are usable.</returns>
    public string? Validate(GlucoseUnit unit = GlucoseUnit.MgPerDl)
    {
        string F(double mgPerDl) => GlucoseUnits.Format(mgPerDl, unit, CultureInfo.CurrentCulture);

        if (LowMgPerDl is < MinLow or > MaxLow)
        {
            return $"The low threshold must be between {F(MinLow)} and {F(MaxLow)} {unit.Label()}.";
        }

        if (HighMgPerDl is < MinHigh or > MaxHigh)
        {
            return $"The high threshold must be between {F(MinHigh)} and {F(MaxHigh)} {unit.Label()}.";
        }

        if (LowMgPerDl >= HighMgPerDl)
        {
            return "The low threshold must be below the high threshold.";
        }

        if (RepeatMinutes is < 0 or > MaxRepeatMinutes)
        {
            return $"The repeat interval must be between 0 and {MaxRepeatMinutes} minutes.";
        }

        return null;
    }
}

/// <summary>An alert that should be delivered now.</summary>
public sealed record AlertRaised(AlertKind Kind, GlucoseReading Reading, bool IsReminder);

/// <summary>
/// Decides when to alert. Pure logic with no UI or clock of its own, so every rule can be tested.
/// One instance follows one stream of readings.
/// </summary>
public sealed class AlertEvaluator
{
    /// <summary>Readings older than this are not acted on (the same limit the display uses for "old reading").</summary>
    public static readonly TimeSpan MaxReadingAge = TimeSpan.FromMinutes(10);

    /// <summary>
    /// After an alert, a reading must move this far back inside the range before the next crossing counts as a
    /// new episode, so a value hovering on the line does not alert repeatedly.
    /// </summary>
    public const double RearmMarginMgPerDl = 5;

    private AlertKind? _episode;
    private DateTimeOffset? _lastRaisedAt;
    private DateTimeOffset _snoozedUntil = DateTimeOffset.MinValue;

    public DateTimeOffset? SnoozedUntil(DateTimeOffset now) => _snoozedUntil > now ? _snoozedUntil : null;

    public void Snooze(DateTimeOffset until) => _snoozedUntil = until;

    public void Resume() => _snoozedUntil = DateTimeOffset.MinValue;

    /// <summary>Forget the current episode, for example after the thresholds change.</summary>
    public void Reset()
    {
        _episode = null;
        _lastRaisedAt = null;
    }

    /// <summary>Which alert zone a reading is in right now, ignoring snooze and history; null when in range, disabled or old.</summary>
    public static AlertKind? Classify(AlertSettings settings, GlucoseReading? current, DateTimeOffset now)
    {
        if (current is null || now - current.TimestampUtc > MaxReadingAge) return null;

        if (settings.LowEnabled && current.MgPerDl < settings.LowMgPerDl) return AlertKind.Low;
        if (settings.HighEnabled && current.MgPerDl > settings.HighMgPerDl) return AlertKind.High;
        return null;
    }

    /// <returns>The alert to deliver, or null when nothing is due.</returns>
    public AlertRaised? Evaluate(AlertSettings settings, GlucoseReading? current, DateTimeOffset now)
    {
        // An old or missing reading says nothing about the present, so it neither alerts nor ends an episode.
        if (current is null || now - current.TimestampUtc > MaxReadingAge) return null;

        var kind = Classify(settings, current, now);
        if (kind is null)
        {
            EndEpisodeIfClear(settings, current.MgPerDl);
            return null;
        }

        if (_episode != kind)
        {
            _episode = kind;
            _lastRaisedAt = null;
        }

        if (now < _snoozedUntil) return null;

        var neverRaised = _lastRaisedAt is null;
        var reminderDue = settings.RepeatMinutes > 0
            && _lastRaisedAt is { } last
            && now - last >= TimeSpan.FromMinutes(settings.RepeatMinutes);
        if (!neverRaised && !reminderDue) return null;

        _lastRaisedAt = now;
        return new AlertRaised(kind.Value, current, IsReminder: !neverRaised);
    }

    private void EndEpisodeIfClear(AlertSettings settings, double mgPerDl)
    {
        var clear = _episode switch
        {
            AlertKind.Low => mgPerDl >= settings.LowMgPerDl + RearmMarginMgPerDl,
            AlertKind.High => mgPerDl <= settings.HighMgPerDl - RearmMarginMgPerDl,
            _ => false,
        };

        // Also clear when that alert has been switched off, otherwise a stale episode would linger.
        var disabled = _episode == AlertKind.Low && !settings.LowEnabled
            || _episode == AlertKind.High && !settings.HighEnabled;

        if (clear || disabled) Reset();
    }
}
