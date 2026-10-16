using System.Net;
using System.Security.Cryptography;
using System.Text;
using LibreMonitor.Core;

namespace LibreMonitor.Core.Tests;

public class LibreLinkUpClientTests
{
    private sealed class StubHandler : HttpMessageHandler
    {
        private readonly Queue<(HttpStatusCode Status, string Body)> _responses = new();
        public List<HttpRequestMessage> Requests { get; } = [];

        public StubHandler Enqueue(string body, HttpStatusCode status = HttpStatusCode.OK)
        {
            _responses.Enqueue((status, body));
            return this;
        }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Requests.Add(request);
            var (status, body) = _responses.Dequeue();
            return Task.FromResult(new HttpResponseMessage(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") });
        }
    }

    private const string LoginOk = """{"status":0,"data":{"user":{"id":"user-123"},"authTicket":{"token":"tok-abc"}}}""";

    private static (LibreLinkUpClient Client, StubHandler Handler) Create(StubHandler handler) =>
        (new LibreLinkUpClient(new HttpClient(handler)), handler);

    [Fact]
    public async Task Login_StoresSession_AndSendsRequiredHeaders()
    {
        var (client, handler) = Create(new StubHandler().Enqueue(LoginOk).Enqueue("""{"status":0,"data":[]}"""));

        await client.LoginAsync("a@b.c", "pw");
        await client.GetPatientsAsync();

        Assert.True(client.IsLoggedIn);
        var login = handler.Requests[0];
        Assert.Equal("https://api.libreview.io/llu/auth/login", login.RequestUri!.ToString());
        Assert.Equal("llu.android", login.Headers.GetValues("product").Single());
        Assert.False(string.IsNullOrWhiteSpace(login.Headers.UserAgent.ToString()), "requests without a User-Agent get HTTP 403");
        Assert.False(string.IsNullOrWhiteSpace(handler.Requests[1].Headers.UserAgent.ToString()));
        Assert.Null(login.Headers.Authorization);

        var read = handler.Requests[1];
        Assert.Equal("Bearer", read.Headers.Authorization!.Scheme);
        Assert.Equal("tok-abc", read.Headers.Authorization.Parameter);
        var expectedHash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("user-123")));
        Assert.Equal(expectedHash, read.Headers.GetValues("account-id").Single());
    }

    [Fact]
    public async Task Login_FollowsRegionRedirect()
    {
        var (client, handler) = Create(new StubHandler()
            .Enqueue("""{"status":0,"data":{"redirect":true,"region":"eu"}}""")
            .Enqueue(LoginOk));

        await client.LoginAsync("a@b.c", "pw");

        Assert.Equal("https://api-eu.libreview.io", client.BaseUrl);
        Assert.Equal("https://api-eu.libreview.io/llu/auth/login", handler.Requests[1].RequestUri!.ToString());
    }

    [Theory]
    [InlineData("evil.example/x")]
    [InlineData("eu.attacker.com")]
    [InlineData("")]
    public async Task Login_RejectsUnsafeRegion_WithoutSendingCredentialsElsewhere(string region)
    {
        var (client, handler) = Create(new StubHandler().Enqueue(
            "{\"status\":0,\"data\":{\"redirect\":true,\"region\":\"" + region + "\"}}"));

        await Assert.ThrowsAsync<LibreLinkUpException>(() => client.LoginAsync("a@b.c", "pw"));

        Assert.Single(handler.Requests);
        Assert.Equal("https://api.libreview.io", client.BaseUrl);
    }

    [Fact]
    public async Task Login_WrongPassword_Throws()
    {
        var (client, _) = Create(new StubHandler().Enqueue("""{"status":2}"""));

        await Assert.ThrowsAsync<InvalidCredentialsException>(() => client.LoginAsync("a@b.c", "bad"));
        Assert.False(client.IsLoggedIn);
    }

    [Theory]
    [InlineData("tou")]
    [InlineData("pp")]
    [InlineData("verifyEmail")]
    public async Task Login_PendingStep_ThrowsActionRequired(string step)
    {
        var (client, _) = Create(new StubHandler().Enqueue(
            "{\"status\":0,\"data\":{\"step\":{\"type\":\"" + step + "\"}}}"));

        var ex = await Assert.ThrowsAsync<AccountActionRequiredException>(() => client.LoginAsync("a@b.c", "pw"));
        Assert.Equal(step, ex.Step);
    }

    [Fact]
    public async Task Login_ErrorMessage_NeverContainsPassword()
    {
        var (client, _) = Create(new StubHandler().Enqueue("{}", HttpStatusCode.InternalServerError));

        var ex = await Assert.ThrowsAsync<LibreLinkUpException>(() => client.LoginAsync("a@b.c", "s3cret-pw"));
        Assert.DoesNotContain("s3cret-pw", ex.ToString());
    }

    [Fact]
    public async Task Read_WithoutLogin_ThrowsSessionExpired()
    {
        var (client, _) = Create(new StubHandler());

        await Assert.ThrowsAsync<SessionExpiredException>(() => client.GetPatientsAsync());
    }

    [Fact]
    public async Task Read_Unauthorized_ClearsSession()
    {
        var (client, _) = Create(new StubHandler().Enqueue(LoginOk).Enqueue("{}", HttpStatusCode.Unauthorized));
        await client.LoginAsync("a@b.c", "pw");

        await Assert.ThrowsAsync<SessionExpiredException>(() => client.GetPatientsAsync());
        Assert.False(client.IsLoggedIn);
    }

    [Fact]
    public async Task GetPatients_ParsesConnections()
    {
        var (client, _) = Create(new StubHandler().Enqueue(LoginOk)
            .Enqueue("""{"status":0,"data":[{"patientId":"p1","firstName":"Ana","lastName":"Silva"}]}"""));
        await client.LoginAsync("a@b.c", "pw");

        var patients = await client.GetPatientsAsync();

        Assert.Equal(new Patient("p1", "Ana", "Silva"), Assert.Single(patients));
    }

    [Fact]
    public async Task GetGraph_ParsesCurrentAndHistory()
    {
        const string graph = """
            {"status":0,"data":{
              "connection":{"glucoseMeasurement":{"FactoryTimestamp":"10/13/2026 8:45:12 PM","ValueInMgPerDl":112,"Value":112,"TrendArrow":4,"isHigh":false,"isLow":false}},
              "graphData":[
                {"FactoryTimestamp":"10/13/2026 8:30:00 PM","ValueInMgPerDl":98,"Value":98,"isHigh":false,"isLow":false},
                {"FactoryTimestamp":"10/13/2026 8:35:00 PM","ValueInMgPerDl":69,"Value":69,"isHigh":false,"isLow":true}
              ]}}
            """;
        var (client, handler) = Create(new StubHandler().Enqueue(LoginOk).Enqueue(graph));
        await client.LoginAsync("a@b.c", "pw");

        var snapshot = await client.GetGraphAsync("p 1");

        Assert.Equal("https://api.libreview.io/llu/connections/p%201/graph", handler.Requests[1].RequestUri!.AbsoluteUri);
        Assert.Equal(new DateTimeOffset(2026, 10, 13, 20, 45, 12, TimeSpan.Zero), snapshot.Current!.TimestampUtc);
        Assert.Equal(112, snapshot.Current.MgPerDl);
        Assert.Equal(Trend.UpSlow, snapshot.Current.Trend);
        Assert.Equal(2, snapshot.History.Count);
        Assert.True(snapshot.History[1].IsLow);
        Assert.Equal(Trend.Unknown, snapshot.History[0].Trend);
    }

    [Fact]
    public async Task GetGraph_WithNoMeasurement_ReturnsNullCurrent()
    {
        var (client, _) = Create(new StubHandler().Enqueue(LoginOk).Enqueue("""{"status":0,"data":{"connection":{},"graphData":[]}}"""));
        await client.LoginAsync("a@b.c", "pw");

        var snapshot = await client.GetGraphAsync("p1");

        Assert.Null(snapshot.Current);
        Assert.Empty(snapshot.History);
    }
}
