using System.Net;
using System.Text;
using LibreMonitor.Core;

namespace LibreMonitor.Core.Tests;

/// <summary>
/// What happens when LibreLinkUp changes, blocks the client, or just has a bad moment. The rule: a response that
/// does not look right is "the service changed" (so the user can be told to look for an update), never a wrong
/// password; ordinary hiccups stay quiet and retryable.
/// </summary>
public class ServiceChangeTests
{
    private sealed class Routes(Func<HttpRequestMessage, (HttpStatusCode, string)> route) : HttpMessageHandler
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

    private static LibreLinkUpClient ClientFor(Func<HttpRequestMessage, (HttpStatusCode, string)> route) =>
        new(new HttpClient(new Routes(route)));

    private static async Task<LibreLinkUpClient> LoggedIn(Func<HttpRequestMessage, (HttpStatusCode, string)> afterLogin)
    {
        var client = ClientFor(r => r.RequestUri!.AbsolutePath.EndsWith("/auth/login") ? (HttpStatusCode.OK, LoginOk) : afterLogin(r));
        await client.LoginAsync("a@b.c", "pw");
        return client;
    }

    // ---- login -------------------------------------------------------------------------------

    [Theory]
    [InlineData(403)]
    [InlineData(404)]
    [InlineData(410)]
    public async Task Login_BlockedOrRemoved_IsServiceChanged(int httpStatus)
    {
        var client = ClientFor(_ => ((HttpStatusCode)httpStatus, "<html>blocked</html>"));

        var ex = await Assert.ThrowsAsync<ServiceChangedException>(() => client.LoginAsync("a@b.c", "pw"));
        Assert.Contains(httpStatus.ToString(), ex.Detail);
    }

    [Theory]
    [InlineData(500)]
    [InlineData(502)]
    [InlineData(429)]
    public async Task Login_ServerErrorOrRateLimit_IsAnOrdinaryRetryableFailure(int httpStatus)
    {
        var client = ClientFor(_ => ((HttpStatusCode)httpStatus, "{}"));

        var ex = await Assert.ThrowsAsync<LibreLinkUpException>(() => client.LoginAsync("a@b.c", "pw"));
        Assert.IsNotType<ServiceChangedException>(ex);
    }

    [Fact]
    public async Task Login_ClientVersionTooOld_SaysWhichVersionIsNeeded()
    {
        var client = ClientFor(_ => (HttpStatusCode.OK, """{"status":920,"data":{"minimumVersion":"4.99.0"}}"""));

        var ex = await Assert.ThrowsAsync<ServiceChangedException>(() => client.LoginAsync("a@b.c", "pw"));
        Assert.Contains("920", ex.Detail);
        Assert.Contains("4.99.0", ex.Detail);
    }

    [Fact]
    public async Task Login_AnyOtherNonZeroStatus_IsServiceChanged_NotAWrongPassword()
    {
        var client = ClientFor(_ => (HttpStatusCode.OK, """{"status":7}"""));

        await Assert.ThrowsAsync<ServiceChangedException>(() => client.LoginAsync("a@b.c", "pw"));
    }

    [Fact]
    public async Task Login_WrongPassword_IsStillAWrongPassword() =>
        await Assert.ThrowsAsync<InvalidCredentialsException>(() =>
            ClientFor(_ => (HttpStatusCode.OK, """{"status":2}""")).LoginAsync("a@b.c", "bad"));

    [Theory]
    [InlineData("""{"status":0}""")]                                              // no data at all
    [InlineData("""{"status":0,"data":{}}""")]                                    // data without a session
    [InlineData("""{"status":0,"data":{"user":{"id":"u"}}}""")]                   // no auth ticket
    [InlineData("""{"status":0,"data":{"authTicket":{"token":"t"}}}""")]          // no user
    [InlineData("<html>Just a moment...</html>")]                                // a challenge page instead of JSON
    [InlineData("[]")]                                                            // JSON, but not an object
    public async Task Login_ResponseInTheWrongShape_IsServiceChanged_NotAWrongPassword(string body)
    {
        var client = ClientFor(_ => (HttpStatusCode.OK, body));

        await Assert.ThrowsAsync<ServiceChangedException>(() => client.LoginAsync("a@b.c", "pw"));
    }

    // ---- reads -------------------------------------------------------------------------------

    [Fact]
    public async Task Connections_MissingList_IsServiceChanged()
    {
        var client = await LoggedIn(_ => (HttpStatusCode.OK, """{"status":0}"""));

        await Assert.ThrowsAsync<ServiceChangedException>(() => client.GetPatientsAsync());
    }

    [Fact]
    public async Task Connections_EmptyList_IsNormal()
    {
        var client = await LoggedIn(_ => (HttpStatusCode.OK, """{"status":0,"data":[]}"""));

        Assert.Empty(await client.GetPatientsAsync());
    }

    [Fact]
    public async Task Connections_ItemWithoutPatientId_IsServiceChanged()
    {
        var client = await LoggedIn(_ => (HttpStatusCode.OK, """{"status":0,"data":[{"firstName":"Ana"}]}"""));

        await Assert.ThrowsAsync<ServiceChangedException>(() => client.GetPatientsAsync());
    }

    [Fact]
    public async Task Graph_NonZeroStatus_IsServiceChanged()
    {
        var client = await LoggedIn(_ => (HttpStatusCode.OK, """{"status":920,"data":{"minimumVersion":"5.0.0"}}"""));

        await Assert.ThrowsAsync<ServiceChangedException>(() => client.GetGraphAsync("p1"));
    }

    [Fact]
    public async Task Graph_NoDataObject_IsServiceChanged()
    {
        var client = await LoggedIn(_ => (HttpStatusCode.OK, """{"status":0}"""));

        await Assert.ThrowsAsync<ServiceChangedException>(() => client.GetGraphAsync("p1"));
    }

    [Fact]
    public async Task Graph_UnrecognisedTimestamp_IsServiceChanged()
    {
        var client = await LoggedIn(_ => (HttpStatusCode.OK,
            """{"status":0,"data":{"connection":{"glucoseMeasurement":{"FactoryTimestamp":"2026-10-13T20:45:12Z","ValueInMgPerDl":112}},"graphData":[]}}"""));

        await Assert.ThrowsAsync<ServiceChangedException>(() => client.GetGraphAsync("p1"));
    }

    [Fact]
    public async Task Graph_NoCurrentReading_IsStillNormal()
    {
        var client = await LoggedIn(_ => (HttpStatusCode.OK, """{"status":0,"data":{"connection":{},"graphData":[]}}"""));

        var snapshot = await client.GetGraphAsync("p1");

        Assert.Null(snapshot.Current);
    }

    [Fact]
    public async Task Read_Forbidden_StillMeansAnExpiredSession_NotAChangedService()
    {
        var client = await LoggedIn(_ => (HttpStatusCode.Forbidden, "{}"));

        await Assert.ThrowsAsync<SessionExpiredException>(() => client.GetPatientsAsync());
    }

    [Fact]
    public void Message_NamesTheProblemAndNeverTheCredentials()
    {
        var ex = new ServiceChangedException("status 920");

        Assert.Contains("status 920", ex.Message);
        Assert.Contains("changed or blocked", ex.Message);
    }

    // ---- the monitor escalates only when it keeps happening ---------------------------------

    private static GlucoseMonitor MonitorFor(Func<HttpRequestMessage, (HttpStatusCode, string)> route) =>
        new(new LibreLinkUpClient(new HttpClient(new Routes(route))), () => ("a@b.c", "pw"), TimeSpan.FromMilliseconds(15));

    [Fact]
    public async Task Monitor_RaisesServiceChanged_OnlyAfterTheThresholdOfFailuresInARow_AndOnlyOnce()
    {
        var monitor = MonitorFor(_ => (HttpStatusCode.Forbidden, "<html>blocked</html>"));
        var failures = 0;
        var raised = new List<int>();
        monitor.Failed += (_, fatal) => { Assert.False(fatal); Interlocked.Increment(ref failures); };
        monitor.ServiceChanged += _ => raised.Add(Volatile.Read(ref failures));
        var enough = new TaskCompletionSource();
        monitor.Failed += (_, _) => { if (Volatile.Read(ref failures) >= GlucoseMonitor.ServiceChangedThreshold + 4) enough.TrySetResult(); };

        monitor.Start();
        await enough.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await monitor.StopAsync();

        Assert.Single(raised); // reported once, not on every failure
        Assert.Equal(GlucoseMonitor.ServiceChangedThreshold, raised[0]); // and not before the threshold
    }

    [Fact]
    public async Task Monitor_AFewOddResponsesAmongGoodOnes_RaiseNothing()
    {
        var polls = 0;
        // Every third graph response is odd; the others are fine, so there is never an unbroken run.
        var monitor = MonitorFor(r => r.RequestUri!.AbsolutePath switch
        {
            var p when p.EndsWith("/auth/login") => (HttpStatusCode.OK, LoginOk),
            var p when p.EndsWith("/connections") => (HttpStatusCode.OK, Patients),
            _ => Interlocked.Increment(ref polls) % 3 == 0 ? (HttpStatusCode.NotFound, "{}") : (HttpStatusCode.OK, Graph),
        });
        var raised = false;
        monitor.ServiceChanged += _ => raised = true;
        var enough = new TaskCompletionSource();
        monitor.Updated += _ => { if (Volatile.Read(ref polls) >= 12) enough.TrySetResult(); };

        monitor.Start();
        await enough.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await monitor.StopAsync();

        Assert.False(raised);
    }

    [Fact]
    public async Task Monitor_AfterRecovery_AReturningProblemIsReportedAgain()
    {
        var broken = true;
        var monitor = MonitorFor(r => r.RequestUri!.AbsolutePath switch
        {
            var p when p.EndsWith("/auth/login") => (HttpStatusCode.OK, LoginOk),
            var p when p.EndsWith("/connections") => (HttpStatusCode.OK, Patients),
            _ => Volatile.Read(ref broken) ? (HttpStatusCode.NotFound, "{}") : (HttpStatusCode.OK, Graph),
        });
        var episodes = 0;
        var first = new TaskCompletionSource();
        var second = new TaskCompletionSource();
        var recovered = new TaskCompletionSource();
        monitor.ServiceChanged += _ =>
        {
            if (Interlocked.Increment(ref episodes) == 1) first.TrySetResult(); else second.TrySetResult();
        };
        monitor.Updated += _ => recovered.TrySetResult();

        monitor.Start();
        await first.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Volatile.Write(ref broken, false);
        await recovered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Volatile.Write(ref broken, true);
        await second.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await monitor.StopAsync();

        Assert.Equal(2, episodes);
    }

    [Fact]
    public async Task Monitor_ServerErrors_AreNeverReportedAsAChangedService()
    {
        var monitor = MonitorFor(_ => (HttpStatusCode.InternalServerError, "{}"));
        var raised = false;
        var failures = 0;
        var enough = new TaskCompletionSource();
        monitor.ServiceChanged += _ => raised = true;
        monitor.Failed += (_, _) => { if (Interlocked.Increment(ref failures) >= 8) enough.TrySetResult(); };

        monitor.Start();
        await enough.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await monitor.StopAsync();

        Assert.False(raised);
    }
}
