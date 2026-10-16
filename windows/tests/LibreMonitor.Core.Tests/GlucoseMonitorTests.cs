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
