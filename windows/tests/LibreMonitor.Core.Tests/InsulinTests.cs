using LibreMonitor.Core;

namespace LibreMonitor.Core.Tests;

public class InsulinTests
{
    private static readonly TimeZoneInfo Utc = TimeZoneInfo.Utc;

    // 2026-10-14 is a Wednesday; UTC is used so the clock times in the tests are the local times.
    private static DateTimeOffset At(int day, int hour, int minute = 0) =>
        new(2026, 10, day, hour, minute, 0, TimeSpan.Zero);

    private static readonly InsulinSettings Once = new(Enabled: true, DosesPerDay: 1, FirstDoseMinutes: 8 * 60, RepeatMinutes: 30);

    private static readonly InsulinSettings Twice = new(
        Enabled: true, DosesPerDay: 2, FirstDoseMinutes: 8 * 60, SecondDoseMinutes: 20 * 60, RepeatMinutes: 30);

    private static DoseState State(InsulinSettings s, DateTimeOffset now) => InsulinSchedule.Status(s, now, Utc).State;

    // ---- status ------------------------------------------------------------------------------

    [Fact]
    public void BeforeThePeriodOpens_TheEarlierDoseIsStillTheCurrentOne()
    {
        // 05:00: the next 08:00 dose opens at 06:00, so the 08:00 dose of the day before is still current.
        var status = InsulinSchedule.Status(Once, At(14, 5), Utc);

        Assert.Equal(DoseState.Due, status.State);
        Assert.Equal(At(13, 8), status.Slot);
    }

    [Fact]
    public void WhenThePeriodOpens_TheStatusIsUpcoming()
    {
        Assert.Equal(DoseState.Upcoming, State(Once, At(14, 6)));
        Assert.Equal(DoseState.Upcoming, State(Once, At(14, 7, 59)));
    }

    [Fact]
    public void AtTheDoseTime_TheStatusIsDue()
    {
        Assert.Equal(DoseState.Due, State(Once, At(14, 8)));
        Assert.Equal(DoseState.Due, State(Once, At(14, 15)));
    }

    [Fact]
    public void MarkedDose_IsAdministered_UntilTheNextPeriodOpens()
    {
        var administered = Once.MarkAdministered(At(14, 8, 12));

        var status = InsulinSchedule.Status(administered, At(14, 8, 13), Utc);
        Assert.Equal(DoseState.Administered, status.State);
        Assert.Equal(At(14, 8, 12), status.AdministeredAt);
        Assert.Equal(DoseState.Administered, State(administered, At(14, 23, 59)));
        Assert.Equal(DoseState.Administered, State(administered, At(15, 5, 59)));
        Assert.Equal(DoseState.Upcoming, State(administered, At(15, 6)));
        Assert.Equal(DoseState.Due, State(administered, At(15, 8)));
    }

    [Fact]
    public void ATapBeforeTheDoseTime_CountsForThatDose()
    {
        var administered = Once.MarkAdministered(At(14, 6, 30));

        Assert.Equal(DoseState.Administered, State(administered, At(14, 6, 31)));
        Assert.Equal(DoseState.Administered, State(administered, At(14, 8, 30)));
        Assert.Equal(DoseState.Upcoming, State(administered, At(15, 6)));
    }

    [Fact]
    public void ATapForYesterdaysDose_DoesNotCountForToday()
    {
        var administered = Once.MarkAdministered(At(13, 8, 5));

        Assert.Equal(DoseState.Due, State(administered, At(14, 8)));
    }

    [Fact]
    public void Undo_RemovesTheMark()
    {
        var administered = Once.MarkAdministered(At(14, 8, 5));

        Assert.Equal(DoseState.Due, State(administered.Undo(), At(14, 9)));
        Assert.Null(administered.Undo().LastAdministeredAt);
    }

    [Fact]
    public void ATimestampInTheFuture_IsNotAdministered()
    {
        var administered = Once.MarkAdministered(At(20, 8));

        Assert.Equal(DoseState.Due, State(administered, At(14, 9)));
    }

    [Fact]
    public void Twice_HasTwoPeriodsADay()
    {
        var morning = Twice.MarkAdministered(At(14, 8, 10));

        Assert.Equal(DoseState.Administered, State(morning, At(14, 9)));
        Assert.Equal(DoseState.Administered, State(morning, At(14, 17, 59)));
        Assert.Equal(DoseState.Upcoming, State(morning, At(14, 18)));
        Assert.Equal(DoseState.Due, State(morning, At(14, 20)));
        Assert.Equal(DoseState.Administered, State(morning.MarkAdministered(At(14, 20, 5)), At(14, 21)));
        Assert.Equal(DoseState.Upcoming, State(morning.MarkAdministered(At(14, 20, 5)), At(15, 6)));
    }

    [Fact]
    public void Twice_MorningTapDoesNotCoverTheEvening()
    {
        var morning = Twice.MarkAdministered(At(14, 8, 10));

        Assert.Equal(DoseState.Due, State(morning, At(14, 20, 1)));
    }

    [Fact]
    public void ADoseNearMidnight_WrapsCorrectly()
    {
        var late = new InsulinSettings(Enabled: true, DosesPerDay: 1, FirstDoseMinutes: 23 * 60 + 30);
        var administered = late.MarkAdministered(At(14, 23, 40));

        Assert.Equal(DoseState.Administered, State(administered, At(15, 1)));
        Assert.Equal(DoseState.Upcoming, State(administered, At(15, 21, 30)));
        Assert.Equal(DoseState.Due, State(administered, At(15, 23, 30)));
    }

    [Fact]
    public void ADoseJustAfterMidnight_CountsAnEveningTapAsEarly()
    {
        var early = new InsulinSettings(Enabled: true, DosesPerDay: 1, FirstDoseMinutes: 30);
        var administered = early.MarkAdministered(At(14, 23, 0)); // within 2 hours before 00:30

        Assert.Equal(DoseState.Administered, State(administered, At(15, 0, 40)));
    }

    [Fact]
    public void TheClockZone_DecidesWhatLocalTimeMeans()
    {
        var plus3 = TimeZoneInfo.CreateCustomTimeZone("plus3", TimeSpan.FromHours(3), "plus3", "plus3");

        // 05:30 UTC is 08:30 at +03:00, so the 08:00 dose is due there but not in UTC.
        Assert.Equal(DoseState.Due, InsulinSchedule.Status(Once, At(14, 5, 30), plus3).State);
        Assert.Equal(DoseState.Due, InsulinSchedule.Status(Once, At(14, 5, 30), Utc).State); // yesterday's, unmarked
        Assert.Equal(At(14, 5), InsulinSchedule.Status(Once, At(14, 5, 30), plus3).Slot);
    }

    [Fact]
    public void ADoseTimeThatDoesNotExistOnADstDay_FallsAfterTheGap()
    {
        if (!TimeZoneInfo.TryFindSystemTimeZoneById("Europe/Lisbon", out var lisbon)) return; // zone data not available

        // Clocks in Lisbon went from 01:00 to 02:00 on 2026-03-29, so 01:30 does not exist that day.
        var settings = new InsulinSettings(Enabled: true, DosesPerDay: 1, FirstDoseMinutes: 90);
        var status = InsulinSchedule.Status(settings, new DateTimeOffset(2026, 3, 29, 1, 30, 0, TimeSpan.Zero), lisbon);

        Assert.Equal(DoseState.Due, status.State);
        Assert.Equal(TimeSpan.FromHours(1), status.Slot.Offset);
        Assert.Equal(2, status.Slot.Hour);
        Assert.Equal(30, status.Slot.Minute);
    }

    // ---- validation --------------------------------------------------------------------------

    [Fact]
    public void Defaults_AreValidAndOff()
    {
        var defaults = new InsulinSettings();

        Assert.False(defaults.Enabled);
        Assert.Null(defaults.Validate());
        Assert.Null(defaults.LastAdministeredAt);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(3)]
    public void DosesPerDay_MustBeOneOrTwo(int doses) => Assert.NotNull(new InsulinSettings(DosesPerDay: doses).Validate());

    [Theory]
    [InlineData(-1)]
    [InlineData(1440)]
    public void Times_MustBeInsideTheDay(int minutes) => Assert.NotNull(new InsulinSettings(FirstDoseMinutes: minutes).Validate());

    [Fact]
    public void TwoDoses_MustBeFarEnoughApart()
    {
        Assert.NotNull(new InsulinSettings(DosesPerDay: 2, FirstDoseMinutes: 8 * 60, SecondDoseMinutes: 10 * 60).Validate());
        Assert.NotNull(new InsulinSettings(DosesPerDay: 2, FirstDoseMinutes: 1 * 60, SecondDoseMinutes: 23 * 60).Validate()); // 2 h round midnight
        Assert.Null(new InsulinSettings(DosesPerDay: 2, FirstDoseMinutes: 8 * 60, SecondDoseMinutes: 12 * 60).Validate());
    }

    [Fact]
    public void TheSecondTime_IsIgnoredForASingleDose()
    {
        Assert.Null(new InsulinSettings(DosesPerDay: 1, FirstDoseMinutes: 8 * 60, SecondDoseMinutes: 8 * 60).Validate());
    }

    [Fact]
    public void RepeatInterval_MustBeInRange()
    {
        Assert.NotNull(new InsulinSettings(RepeatMinutes: -1).Validate());
        Assert.NotNull(new InsulinSettings(RepeatMinutes: AlertSettings.MaxRepeatMinutes + 1).Validate());
    }

    // ---- reminders ---------------------------------------------------------------------------

    private static InsulinReminderRaised? Step(InsulinReminderEvaluator e, InsulinSettings s, DateTimeOffset at,
        DateTimeOffset? snoozedUntil = null) => e.Evaluate(s, at, Utc, snoozedUntil);

    [Fact]
    public void NothingIsRaised_BeforeTheDoseTime()
    {
        Assert.Null(Step(new InsulinReminderEvaluator(), Once, At(14, 7, 59)));
    }

    [Fact]
    public void Disabled_NeverRaises()
    {
        Assert.Null(Step(new InsulinReminderEvaluator(), Once with { Enabled = false }, At(14, 8)));
    }

    [Fact]
    public void RaisesAtTheDoseTime_ThenRepeats()
    {
        var e = new InsulinReminderEvaluator();

        var first = Step(e, Once, At(14, 8));
        Assert.False(first!.IsReminder);
        Assert.Equal(At(14, 8), first.Slot);
        Assert.Null(Step(e, Once, At(14, 8, 29)));

        var again = Step(e, Once, At(14, 8, 30));
        Assert.True(again!.IsReminder);
        Assert.Null(Step(e, Once, At(14, 8, 45)));
        Assert.NotNull(Step(e, Once, At(14, 9)));
    }

    [Fact]
    public void MarkingTheDose_StopsReminders_AndAllowsTheNextDose()
    {
        var e = new InsulinReminderEvaluator();
        Assert.NotNull(Step(e, Once, At(14, 8)));

        var administered = Once.MarkAdministered(At(14, 8, 10));
        Assert.Null(Step(e, administered, At(14, 8, 30)));
        Assert.Null(Step(e, administered, At(15, 7)));
        Assert.NotNull(Step(e, administered, At(15, 8)));
    }

    [Fact]
    public void RepeatZero_RemindsOnlyOnce()
    {
        var e = new InsulinReminderEvaluator();
        var once = Once with { RepeatMinutes = 0 };

        Assert.NotNull(Step(e, once, At(14, 8)));
        Assert.Null(Step(e, once, At(14, 9)));
        Assert.Null(Step(e, once, At(14, 12)));
    }

    [Fact]
    public void Reminders_StopAfterTheReminderWindow_ButTheDoseStaysDue()
    {
        var e = new InsulinReminderEvaluator();
        Assert.NotNull(Step(e, Once, At(14, 8)));
        Assert.NotNull(Step(e, Once, At(14, 13, 30)));

        Assert.Null(Step(e, Once, At(14, 14, 1)));
        Assert.Null(Step(e, Once, At(14, 23)));
        Assert.Null(Step(e, Once, At(15, 3)));
        Assert.Equal(DoseState.Due, State(Once, At(15, 3)));
    }

    [Fact]
    public void ALateStart_InsideTheWindow_RaisesImmediately_OutsideItDoesNot()
    {
        Assert.NotNull(Step(new InsulinReminderEvaluator(), Once, At(14, 10)));
        Assert.Null(Step(new InsulinReminderEvaluator(), Once, At(14, 20)));
    }

    [Fact]
    public void Snooze_HoldsTheReminder_ThenRaisesWhenItEnds()
    {
        var e = new InsulinReminderEvaluator();
        var until = At(14, 9);

        Assert.Null(Step(e, Once, At(14, 8), until));
        Assert.Null(Step(e, Once, At(14, 8, 59), until));

        var raised = Step(e, Once, At(14, 9), until);
        Assert.NotNull(raised);
        Assert.False(raised!.IsReminder);
    }

    [Fact]
    public void Twice_EachDoseIsItsOwnEpisode()
    {
        var e = new InsulinReminderEvaluator();
        Assert.NotNull(Step(e, Twice, At(14, 8)));
        var morningAdministered = Twice.MarkAdministered(At(14, 8, 5));
        Assert.Null(Step(e, morningAdministered, At(14, 12)));

        var evening = Step(e, morningAdministered, At(14, 20));
        Assert.False(evening!.IsReminder);
        Assert.Equal(At(14, 20), evening.Slot);
    }

    [Fact]
    public void Reset_StartsAFreshEpisode()
    {
        var e = new InsulinReminderEvaluator();
        Assert.NotNull(Step(e, Once, At(14, 8)));

        e.Reset();

        var raised = Step(e, Once, At(14, 8, 1));
        Assert.False(raised!.IsReminder);
    }
}
