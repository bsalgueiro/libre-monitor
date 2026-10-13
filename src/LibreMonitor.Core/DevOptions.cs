namespace LibreMonitor.Core;

/// <summary>
/// Developer switches from the command line. They only take effect when the caller says developer features are
/// allowed, which the app does only for builds run from source; a published executable passes false and can never enable them.
/// </summary>
public sealed record DevOptions(bool Enabled, int? Scenario)
{
    public static DevOptions None { get; } = new(false, null);

    /// <summary>
    /// <c>--dev</c> turns developer mode on. <c>--simulate N</c> also turns it on and starts with scenario N showing.
    /// </summary>
    /// <param name="allowed">False in builds where developer features must never appear: the result is then always <see cref="None"/>.</param>
    public static DevOptions Parse(IReadOnlyList<string> args, bool allowed)
    {
        if (!allowed) return None;

        var dev = args.Any(a => a.Equals("--dev", StringComparison.OrdinalIgnoreCase));

        int? scenario = null;
        var flag = args.ToList().FindIndex(a => a.Equals("--simulate", StringComparison.OrdinalIgnoreCase));
        if (flag >= 0 && flag + 1 < args.Count
            && int.TryParse(args[flag + 1], out var n) && n >= 0 && n < Simulation.Scenarios.Count)
        {
            scenario = n;
        }

        return new DevOptions(dev || scenario is not null, scenario);
    }
}
