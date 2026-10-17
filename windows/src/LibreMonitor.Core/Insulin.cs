namespace LibreMonitor.Core;

/// <summary>Where one daily insulin dose stands. Only a memory aid: the app cannot know about doses that were not tapped.</summary>
public enum DoseState
{
    /// <summary>The next dose is not due yet and nothing has been marked for it.</summary>
    Upcoming,

    /// <summary>The dose time has passed and the dose has not been marked as administered.</summary>
    Due,

    /// <summary>The user marked this dose as administered.</summary>
    Administered,
}

/// <summary>
/// Settings for the daily insulin reminder, plus the time the user last marked a dose as administered.
/// That one timestamp is all that is kept: no amounts and no history. The reminder is off by default.
/// </summary>
/// <param name="DosesPerDay">1 or 2.</param>
/// <param name="FirstDoseMinutes">Minutes after local midnight.</param>
/// <param name="SecondDoseMinutes">Minutes after local midnight; only used when <paramref name="DosesPerDay"/> is 2.</param>
/// <param name="RepeatMinutes">Reminder interval while the dose is still not marked; 0 means remind once.</param>
/// <param name="LastAdministeredAt">When the user last tapped "administered"; null if never or undone.</param>
public sealed record InsulinSettings(
    bool Enabled = false,
    int DosesPerDay = 1,
    int FirstDoseMinutes = 8 * 60,
    int SecondDoseMinutes = 20 * 60,
    int RepeatMinutes = 30,
    DateTimeOffset? LastAdministeredAt = null)
{
    /// <summary>With two doses a day, the two times must be at least this far apart (both ways round the clock).</summary>
    public const int MinGapMinutes = 4 * 60;

    /// <summary>The dose times, earliest first.</summary>
    public IReadOnlyList<int> DoseMinutes() =>
        DosesPerDay == 2 ? new[] { FirstDoseMinutes, SecondDoseMinutes }.Order().ToArray() : new[] { FirstDoseMinutes };

    /// <returns>A message describing the first problem, or null when the settings are usable.</returns>
    public string? Validate()
    {
        if (DosesPerDay is not (1 or 2)) return "Choose one or two doses a day.";

        if (FirstDoseMinutes is < 0 or >= 1440 || SecondDoseMinutes is < 0 or >= 1440)
        {
            return "Enter a valid time for each dose.";
        }

        if (DosesPerDay == 2)
        {
            var gap = Math.Abs(FirstDoseMinutes - SecondDoseMinutes);
            if (gap < MinGapMinutes || 1440 - gap < MinGapMinutes)
            {
                return $"The two dose times must be at least {MinGapMinutes / 60} hours apart.";
            }
        }

        if (RepeatMinutes is < 0 or > AlertSettings.MaxRepeatMinutes)
        {
            return $"The repeat interval must be between 0 and {AlertSettings.MaxRepeatMinutes} minutes.";
        }

        return null;
    }

    /// <summary>The same settings with the current dose marked as administered now.</summary>
    public InsulinSettings MarkAdministered(DateTimeOffset now) => this with { LastAdministeredAt = now };

    /// <summary>The same settings with the "administered" mark removed (for a tap by mistake).</summary>
    public InsulinSettings Undo() => this with { LastAdministeredAt = null };
}

/// <summary>Where the current dose stands.</summary>
/// <param name="Slot">The scheduled time of the dose this status is about.</param>
/// <param name="AdministeredAt">When it was marked administered; only set when <paramref name="State"/> is <see cref="DoseState.Administered"/>.</param>
public sealed record DoseStatus(DoseState State, DateTimeOffset Slot, DateTimeOffset? AdministeredAt);

/// <summary>
/// Works out which dose a moment belongs to. Pure logic with no UI or clock of its own, so every rule can be tested.
///
/// A dose "period" starts <see cref="EarlyWindow"/> before the scheduled time and ends <see cref="EarlyWindow"/> before the
/// next scheduled time. A tap counts for the period it falls in, so tapping a little early still counts for that dose,
/// and the status goes back to <see cref="DoseState.Upcoming"/> when the next period opens.
/// </summary>
public static class InsulinSchedule
{
    public static readonly TimeSpan EarlyWindow = TimeSpan.FromHours(2);

    /// <returns>The scheduled time of the dose whose period contains <paramref name="moment"/>.</returns>
    public static DateTimeOffset SlotFor(InsulinSettings settings, DateTimeOffset moment, TimeZoneInfo zone)
    {
        var day = TimeZoneInfo.ConvertTime(moment, zone).Date;
        var limit = moment + EarlyWindow;
        DateTimeOffset? best = null;

        for (var offset = -1; offset <= 1; offset++)
        {
            foreach (var minutes in settings.DoseMinutes())
            {
                var slot = SlotAt(day.AddDays(offset), minutes, zone);
                if (slot <= limit && (best is null || slot > best)) best = slot;
            }
        }

        // The previous day always has a slot at or before the limit, so this is never null.
        return best!.Value;
    }

    public static DoseStatus Status(InsulinSettings settings, DateTimeOffset now, TimeZoneInfo zone)
    {
        var slot = SlotFor(settings, now, zone);

        if (settings.LastAdministeredAt is { } administered && SlotFor(settings, administered, zone) == slot)
        {
            return new DoseStatus(DoseState.Administered, slot, administered);
        }

        return new DoseStatus(now >= slot ? DoseState.Due : DoseState.Upcoming, slot, null);
    }

    private static DateTimeOffset SlotAt(DateTime day, int minutes, TimeZoneInfo zone)
    {
        var local = DateTime.SpecifyKind(day.Date.AddMinutes(minutes), DateTimeKind.Unspecified);
        if (zone.IsInvalidTime(local)) local = local.AddHours(1); // the clock skipped this time (spring forward)
        return new DateTimeOffset(local, zone.GetUtcOffset(local));
    }
}

/// <summary>A dose reminder that should be delivered now.</summary>
public sealed record InsulinReminderRaised(DateTimeOffset Slot, bool IsReminder);

/// <summary>
/// Decides when to remind about a dose that is due and not marked as administered. One instance follows one schedule.
/// Reminders repeat at the chosen interval until the dose is marked or <see cref="ReminderWindow"/> has passed.
/// The dose still shows as due after that, but the app stops notifying (no night-time reminders for a missed dose).
/// </summary>
public sealed class InsulinReminderEvaluator
{
    /// <summary>How long after the scheduled time reminders keep coming.</summary>
    public static readonly TimeSpan ReminderWindow = TimeSpan.FromHours(6);

    private DateTimeOffset? _episodeSlot;
    private DateTimeOffset? _lastRaisedAt;

    /// <summary>Forget the current episode, for example after the schedule changes.</summary>
    public void Reset()
    {
        _episodeSlot = null;
        _lastRaisedAt = null;
    }

    /// <param name="snoozedUntil">The shared alert snooze, if one is active; a snoozed reminder is raised once the snooze ends.</param>
    /// <returns>The reminder to deliver, or null when nothing is due.</returns>
    public InsulinReminderRaised? Evaluate(
        InsulinSettings settings, DateTimeOffset now, TimeZoneInfo zone, DateTimeOffset? snoozedUntil = null)
    {
        if (!settings.Enabled)
        {
            Reset();
            return null;
        }

        var status = InsulinSchedule.Status(settings, now, zone);
        if (status.State != DoseState.Due)
        {
            Reset();
            return null;
        }

        if (_episodeSlot != status.Slot)
        {
            _episodeSlot = status.Slot;
            _lastRaisedAt = null;
        }

        if (now - status.Slot > ReminderWindow) return null;
        if (snoozedUntil is { } until && now < until) return null;

        var neverRaised = _lastRaisedAt is null;
        var reminderDue = settings.RepeatMinutes > 0
            && _lastRaisedAt is { } last
            && now - last >= TimeSpan.FromMinutes(settings.RepeatMinutes);
        if (!neverRaised && !reminderDue) return null;

        _lastRaisedAt = now;
        return new InsulinReminderRaised(status.Slot, IsReminder: !neverRaised);
    }
}
