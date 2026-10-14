namespace LibreMonitor.Core;

public sealed record MonitorUpdate(Patient Patient, GlucoseSnapshot Snapshot, DateTimeOffset FetchedAt);

/// <summary>
/// Polls LibreLinkUp on a fixed interval and reports each result through events.
/// Events are raised on a background thread. Read-only: it only logs in and fetches.
/// </summary>
public sealed class GlucoseMonitor : IAsyncDisposable
{
    /// <summary>The phone uploads about once a minute, so polling faster than this gains nothing.</summary>
    public static readonly TimeSpan DefaultInterval = TimeSpan.FromSeconds(60);

    private readonly LibreLinkUpClient _client;
    private readonly Func<(string Email, string Password)> _credentials;
    private readonly TimeSpan _interval;

    /// <summary>
    /// How many polls in a row must find the service changed before <see cref="ServiceChanged"/> is raised. One odd
    /// response can be a hiccup; a few in a row (about three minutes at the default interval) is a real change.
    /// </summary>
    public const int ServiceChangedThreshold = 3;

    private CancellationTokenSource? _cts;
    private Task? _loop;
    private Patient? _patient;
    private int _changedStreak;
    private bool _changedReported;

    public GlucoseMonitor(
        LibreLinkUpClient client,
        Func<(string Email, string Password)> credentials,
        TimeSpan? interval = null)
    {
        _client = client;
        _credentials = credentials;
        _interval = interval ?? DefaultInterval;
    }

    public event Action<MonitorUpdate>? Updated;

    /// <summary>A poll failed. The bool is true for fatal failures, which stop the monitor; the rest are retried on the next tick.</summary>
    public event Action<Exception, bool>? Failed;

    /// <summary>
    /// The service has kept answering in a way this version does not understand (blocked, new format, newer client
    /// required). Raised once per episode, after <see cref="ServiceChangedThreshold"/> failures in a row; a successful
    /// poll ends the episode, so a later change is reported again. A newer version of the app may be needed.
    /// </summary>
    public event Action<ServiceChangedException>? ServiceChanged;

    public void Start()
    {
        if (_loop is not null) throw new InvalidOperationException("Monitor already started.");
        _cts = new CancellationTokenSource();
        _loop = RunAsync(_cts.Token);
    }

    public async Task StopAsync()
    {
        if (_cts is null || _loop is null) return;
        await _cts.CancelAsync().ConfigureAwait(false);
        try { await _loop.ConfigureAwait(false); } catch (OperationCanceledException) { }
        _cts.Dispose();
        _cts = null;
        _loop = null;
    }

    public ValueTask DisposeAsync() => new(StopAsync());

    private async Task RunAsync(CancellationToken ct)
    {
        using var timer = new PeriodicTimer(_interval);
        do
        {
            if (!await PollOnceAsync(ct).ConfigureAwait(false)) return;
        }
        while (await timer.WaitForNextTickAsync(ct).ConfigureAwait(false));
    }

    /// <returns>false when a fatal error means polling should stop.</returns>
    private async Task<bool> PollOnceAsync(CancellationToken ct)
    {
        try
        {
            if (!_client.IsLoggedIn)
            {
                var (email, password) = _credentials();
                await _client.LoginAsync(email, password, ct).ConfigureAwait(false);
            }

            // The followed person is looked up once and cached; only the graph is fetched on later ticks.
            _patient ??= (await _client.GetPatientsAsync(ct).ConfigureAwait(false)).FirstOrDefault()
                ?? throw new LibreLinkUpException("This account is not following anyone yet.");

            var snapshot = await _client.GetGraphAsync(_patient.PatientId, ct).ConfigureAwait(false);

            _changedStreak = 0;
            _changedReported = false;
            Updated?.Invoke(new MonitorUpdate(_patient, snapshot, DateTimeOffset.UtcNow));
            return true;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            return false;
        }
        catch (Exception ex) when (ex is InvalidCredentialsException or AccountActionRequiredException)
        {
            Failed?.Invoke(ex, true);
            return false;
        }
        catch (ServiceChangedException ex)
        {
            Failed?.Invoke(ex, false);

            if (++_changedStreak >= ServiceChangedThreshold && !_changedReported)
            {
                _changedReported = true;
                ServiceChanged?.Invoke(ex);
            }

            return true;
        }
        catch (Exception ex) when (ex is LibreLinkUpException or HttpRequestException or TaskCanceledException)
        {
            // Session expiry already cleared the token, so the next tick logs in again. Only an unbroken run of
            // "service changed" answers counts towards the warning, so any other outcome starts the count again.
            _changedStreak = 0;
            Failed?.Invoke(ex, false);
            return true;
        }
    }
}
