using System.Net;
using System.Text;
using LibreMonitor.Core;

namespace LibreMonitor.Core.Tests;

public class GlucoseMonitorTests
{
    private sealed class RouteHandler(Func<HttpRequestMessage, (HttpStatusCode, string)> route) : HttpMessageHandler
    {
        public int Logins;

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            if (request.RequestUri!.AbsolutePath.EndsWith("/auth/login")) Interlocked.Increment(ref Logins);
            var (status, body) = route(request);
            return Task.FromResult(new HttpResponseMessage(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") });
        }
    }

    private const string LoginOk = """{"status":0,"data":{"user":{"id":"u"},"authTicket":{"token":"t"}}}""";
    private const string Patients = """{"status":0,"data":[{"patientId":"p1","firstName":"Ana","lastName":"Silva"}]}""";
    private const string Graph = """{"status":0,"data":{"connection":{"glucoseMeasurement":{"FactoryTimestamp":"10/13/2026 8:45:12 PM","ValueInMgPerDl":112,"Value":112,"TrendArrow":3}},"graphData":[]}}""";

    private static GlucoseMonitor Create(RouteHandler handler) =>
        new(new LibreLinkUpClient(new HttpClient(handler)), () => ("a@b.c", "pw"), TimeSpan.FromMilliseconds(20));

    [Fact]
    public async Task Start_LogsIn_AndRaisesUpdates()
    {
        var handler = new RouteHandler(r => r.RequestUri!.AbsolutePath switch
        {
            var p when p.EndsWith("/auth/login") => (HttpStatusCode.OK, LoginOk),
            var p when p.EndsWith("/connections") => (HttpStatusCode.OK, Patients),
            _ => (HttpStatusCode.OK, Graph),
        });
        await using var monitor = Create(handler);
        var updates = new TaskCompletionSource<MonitorUpdate>();
        monitor.Updated += u => updates.TrySetResult(u);

        monitor.Start();
        var update = await updates.Task.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal("Ana", update.Patient.FirstName);
        Assert.Equal(112, update.Snapshot.Current!.MgPerDl);
        Assert.Equal(1, handler.Logins);
    }

    /// <summary>A clock the test moves by hand, so the refresh limits can be checked without waiting.</summary>
    private sealed class FakeClock : TimeProvider
    {
        private DateTimeOffset _now = new(2026, 10, 17, 12, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => _now;
        public void Advance(TimeSpan by) => _now += by;
    }

    private static readonly RouteHandler OkHandler = new(r => r.RequestUri!.AbsolutePath switch
    {
        var p when p.EndsWith("/auth/login") => (HttpStatusCode.OK, LoginOk),
        var p when p.EndsWith("/connections") => (HttpStatusCode.OK, Patients),
        _ => (HttpStatusCode.OK, Graph),
    });

    /// <summary>A monitor that polls once an hour, so every further poll in a test comes from RefreshNow.</summary>
    private sealed class RefreshRig : IAsyncDisposable
    {
        private readonly SemaphoreSlim _updates = new(0);
        public FakeClock Clock { get; } = new();
        public GlucoseMonitor Monitor { get; }
        public int Updates;

        public RefreshRig()
        {
            Monitor = new GlucoseMonitor(
                new LibreLinkUpClient(new HttpClient(OkHandler)), () => ("a@b.c", "pw"), TimeSpan.FromHours(1), Clock);
            Monitor.Updated += _ =>
            {
                Interlocked.Increment(ref Updates);
                _updates.Release();
            };
        }

        public async Task StartAndWaitForFirstPollAsync()
        {
            Monitor.Start();
            await NextUpdateAsync();
            await Task.Delay(100); // let the loop reach its wait
        }

        public Task NextUpdateAsync() => _updates.WaitAsync(TimeSpan.FromSeconds(5));

        public ValueTask DisposeAsync() => Monitor.DisposeAsync();
    }

    [Fact]
    public async Task RefreshNow_AfterTheMinimumGap_PollsAgainWithoutWaitingForTheInterval()
    {
        await using var rig = new RefreshRig();
        await rig.StartAndWaitForFirstPollAsync();

        rig.Clock.Advance(GlucoseMonitor.MinPollGap);

        Assert.True(rig.Monitor.RefreshNow());
        await rig.NextUpdateAsync();
        Assert.Equal(2, rig.Updates);
    }

    [Fact]
    public async Task RefreshNow_RightAfterAPoll_IsRefused()
    {
        await using var rig = new RefreshRig();
        await rig.StartAndWaitForFirstPollAsync();

        rig.Clock.Advance(GlucoseMonitor.MinPollGap - TimeSpan.FromSeconds(1));

        Assert.False(rig.Monitor.RefreshNow());
        await Task.Delay(300);
        Assert.Equal(1, rig.Updates); // nothing was fetched
    }

    [Fact]
    public async Task RefreshNow_Repeated_OnlyTheFirstClickCounts()
    {
        await using var rig = new RefreshRig();
        await rig.StartAndWaitForFirstPollAsync();
        rig.Clock.Advance(GlucoseMonitor.MinPollGap);

        var accepted = 0;
        for (var i = 0; i < 20; i++)
        {
            if (rig.Monitor.RefreshNow()) accepted++;
        }

        await rig.NextUpdateAsync();
        await Task.Delay(300);
        Assert.Equal(1, accepted);
        Assert.Equal(2, rig.Updates); // 20 clicks, one request
    }

    [Fact]
    public async Task RefreshNow_IsLimitedToAFewTimesInTenMinutes_ThenAllowedAgain()
    {
        await using var rig = new RefreshRig();
        await rig.StartAndWaitForFirstPollAsync();

        // Spaced just wider than the gap, the clicks are only stopped by the cap.
        for (var i = 0; i < GlucoseMonitor.MaxManualRefreshes; i++)
        {
            rig.Clock.Advance(GlucoseMonitor.MinPollGap);
            Assert.True(rig.Monitor.RefreshNow(), $"refresh {i + 1} should be allowed");
            await rig.NextUpdateAsync();
            await Task.Delay(50); // let the loop reach its wait again
        }

        rig.Clock.Advance(GlucoseMonitor.MinPollGap);
        Assert.False(rig.Monitor.RefreshNow()); // over the cap
        await Task.Delay(300);
        Assert.Equal(1 + GlucoseMonitor.MaxManualRefreshes, rig.Updates);

        rig.Clock.Advance(GlucoseMonitor.ManualRefreshWindow); // the window has passed
        Assert.True(rig.Monitor.RefreshNow());
        await rig.NextUpdateAsync();
    }

    [Fact]
    public async Task RefreshNow_BeforeStart_DoesNothing()
    {
        var handler = new RouteHandler(_ => (HttpStatusCode.OK, LoginOk));
        await using var monitor = Create(handler);

        var started = monitor.RefreshNow(); // never started: must not throw or poll

        Assert.False(started);
        Assert.Equal(0, handler.Logins);
    }

    /// <summary>Answers the login and patient requests at once, but holds the graph request until released.</summary>
    private sealed class GatedHandler : HttpMessageHandler
    {
        public TaskCompletionSource GraphRequested { get; } = new();
        public TaskCompletionSource ReleaseGraph { get; } = new();

        private static HttpResponseMessage Json(string body) =>
            new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path.EndsWith("/auth/login")) return Json(LoginOk);
            if (path.EndsWith("/connections")) return Json(Patients);

            GraphRequested.TrySetResult();
            await ReleaseGraph.Task.WaitAsync(ct);
            return Json(Graph);
        }
    }

    [Fact]
    public async Task RefreshNow_WhileAPollIsRunning_IsRefused()
    {
        var handler = new GatedHandler();
        var clock = new FakeClock();
        await using var monitor = new GlucoseMonitor(
            new LibreLinkUpClient(new HttpClient(handler)), () => ("a@b.c", "pw"), TimeSpan.FromHours(1), clock);
        var updated = new TaskCompletionSource();
        monitor.Updated += _ => updated.TrySetResult();

        monitor.Start();
        await handler.GraphRequested.Task.WaitAsync(TimeSpan.FromSeconds(5)); // the first poll is in flight

        // Long past the minimum gap, so only the running poll can be the reason for the refusal.
        clock.Advance(GlucoseMonitor.MinPollGap * 2);
        Assert.False(monitor.RefreshNow());

        handler.ReleaseGraph.TrySetResult();
        await updated.Task.WaitAsync(TimeSpan.FromSeconds(5));
    }

    [Fact]
    public async Task ExpiredSession_LogsInAgain_AndKeepsPolling()
    {
        var graphCalls = 0;
        var handler = new RouteHandler(r => r.RequestUri!.AbsolutePath switch
        {
            var p when p.EndsWith("/auth/login") => (HttpStatusCode.OK, LoginOk),
            var p when p.EndsWith("/connections") => (HttpStatusCode.OK, Patients),
            _ => Interlocked.Increment(ref graphCalls) == 1 ? (HttpStatusCode.Unauthorized, "{}") : (HttpStatusCode.OK, Graph),
        });
        await using var monitor = Create(handler);
        var recovered = new TaskCompletionSource();
        var sawNonFatal = false;
        monitor.Failed += (_, fatal) => sawNonFatal = !fatal;
        monitor.Updated += _ => recovered.TrySetResult();

        monitor.Start();
        await recovered.Task.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.True(sawNonFatal);
        Assert.Equal(2, handler.Logins);
    }

    [Fact]
    public async Task WrongPassword_IsFatal_AndStopsPolling()
    {
        var handler = new RouteHandler(_ => (HttpStatusCode.OK, """{"status":2}"""));
        await using var monitor = Create(handler);
        var failed = new TaskCompletionSource<bool>();
        monitor.Failed += (_, fatal) => failed.TrySetResult(fatal);

        monitor.Start();

        Assert.True(await failed.Task.WaitAsync(TimeSpan.FromSeconds(5)));
        await Task.Delay(100);
        Assert.Equal(1, handler.Logins);
    }
}
