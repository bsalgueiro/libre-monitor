using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace LibreMonitor.Core;

/// <summary>
/// Read-only client for the unofficial LibreLinkUp follower API.
/// It only logs in and reads; nothing here writes data to the account.
/// </summary>
public sealed partial class LibreLinkUpClient
{
    private const int MaxRedirects = 2;

    private readonly HttpClient _http;
    private readonly LibreLinkUpOptions _options;

    private string _baseUrl;
    private string? _token;
    private string? _accountIdHash;

    public LibreLinkUpClient(HttpClient http, LibreLinkUpOptions? options = null)
    {
        _http = http;
        _options = options ?? new LibreLinkUpOptions();
        _baseUrl = _options.BaseUrl.TrimEnd('/');
    }

    public string BaseUrl => _baseUrl;

    public bool IsLoggedIn => _token is not null;

    public async Task LoginAsync(string email, string password, CancellationToken ct = default)
    {
        var body = JsonSerializer.Serialize(new { email, password });

        for (var attempt = 0; attempt <= MaxRedirects; attempt++)
        {
            using var request = CreateRequest(HttpMethod.Post, "/llu/auth/login", authenticated: false);
            request.Content = new StringContent(body, Encoding.UTF8, "application/json");

            using var response = await _http.SendAsync(request, ct).ConfigureAwait(false);
            using var doc = await ReadJsonAsync(response, ct).ConfigureAwait(false);
            var root = doc.RootElement;

            if (root.ValueKind == JsonValueKind.Object
                && root.TryGetProperty("status", out var status)
                && status.ValueKind == JsonValueKind.Number
                && status.TryGetInt32(out var statusCode)
                && statusCode == 2)
            {
                throw new InvalidCredentialsException();
            }

            // Anything else that is not a normal success is the service behaving differently, not a wrong password.
            ThrowIfUnexpectedStatus(root);

            if (!root.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Object)
            {
                throw new ServiceChangedException("the login response has no data");
            }

            if (data.TryGetProperty("redirect", out var redirect) && redirect.ValueKind == JsonValueKind.True)
            {
                // The region comes from the server, so it is validated before it becomes part of a host name.
                var region = data.TryGetProperty("region", out var r) ? r.GetString() : null;
                if (region is null || !RegionPattern().IsMatch(region))
                {
                    throw new LibreLinkUpException("Login redirected to an unrecognised region.");
                }

                _baseUrl = $"https://api-{region.ToLowerInvariant()}.libreview.io";
                continue;
            }

            if (data.TryGetProperty("step", out var step) && step.TryGetProperty("type", out var type))
            {
                throw new AccountActionRequiredException(type.GetString() ?? "unknown");
            }

            if (!data.TryGetProperty("authTicket", out var ticket)
                || !ticket.TryGetProperty("token", out var token)
                || !data.TryGetProperty("user", out var user)
                || !user.TryGetProperty("id", out var userId))
            {
                throw new ServiceChangedException("the login response has no session details");
            }

            _token = token.GetString();
            _accountIdHash = Sha256Hex(userId.GetString() ?? string.Empty);
            return;
        }

        throw new LibreLinkUpException("Too many login redirects.");
    }

    public async Task<IReadOnlyList<Patient>> GetPatientsAsync(CancellationToken ct = default)
    {
        using var doc = await GetAsync("/llu/connections", ct).ConfigureAwait(false);
        ThrowIfUnexpectedStatus(doc.RootElement);

        // An empty list is a normal answer (nobody is shared yet); a missing list is not.
        if (!doc.RootElement.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array)
        {
            throw new ServiceChangedException("the connections response has no list");
        }

        var patients = new List<Patient>();
        foreach (var item in data.EnumerateArray())
        {
            if (!item.TryGetProperty("patientId", out var id) || id.GetString() is not { } patientId)
            {
                throw new ServiceChangedException("a connection has no patient id");
            }

            patients.Add(new Patient(patientId, GetString(item, "firstName"), GetString(item, "lastName")));
        }

        return patients;
    }

    /// <summary>
    /// The raw connections answer, for the command-line probe that shows what the service reports about the sensor.
    /// The caller disposes it. Read-only, like every other call here.
    /// </summary>
    public async Task<JsonDocument> GetConnectionsDocumentAsync(CancellationToken ct = default)
    {
        var doc = await GetAsync("/llu/connections", ct).ConfigureAwait(false);
        ThrowIfUnexpectedStatus(doc.RootElement);
        return doc;
    }

    /// <summary>The raw graph answer, for the same probe. The caller disposes it.</summary>
    public async Task<JsonDocument> GetGraphDocumentAsync(string patientId, CancellationToken ct = default)
    {
        var doc = await GetAsync($"/llu/connections/{Uri.EscapeDataString(patientId)}/graph", ct).ConfigureAwait(false);
        ThrowIfUnexpectedStatus(doc.RootElement);
        return doc;
    }

    public async Task<GlucoseSnapshot> GetGraphAsync(string patientId, CancellationToken ct = default)
    {
        using var doc = await GetAsync($"/llu/connections/{Uri.EscapeDataString(patientId)}/graph", ct).ConfigureAwait(false);

        ThrowIfUnexpectedStatus(doc.RootElement);

        if (!doc.RootElement.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Object)
        {
            throw new ServiceChangedException("the graph response has no data");
        }

        // No current measurement is a normal answer (sensor warming up or out of range); a changed format is not.
        GlucoseReading? current = null;
        var history = new List<GlucoseReading>();

        if (data.TryGetProperty("connection", out var connection)
            && connection.TryGetProperty("glucoseMeasurement", out var latest)
            && latest.ValueKind == JsonValueKind.Object)
        {
            current = ParseReading(latest);
        }

        if (data.TryGetProperty("graphData", out var graph) && graph.ValueKind == JsonValueKind.Array)
        {
            history.AddRange(graph.EnumerateArray().Select(ParseReading));
        }

        return new GlucoseSnapshot(current, history, ParseSensor(data));
    }

    /// <summary>
    /// The activation time of the sensor in use, or null when the service does not say. The answer is optional extra
    /// information, so anything unexpected here means "unknown", never a service change. Only the activation time is
    /// read: the serial number and device ids are never touched.
    /// </summary>
    private static SensorInfo? ParseSensor(JsonElement data)
    {
        DateTimeOffset? newest = null;

        void Consider(JsonElement sensor)
        {
            if (sensor.ValueKind != JsonValueKind.Object) return;

            // "s" says whether the sensor is the active one; only an explicit false rules it out.
            if (sensor.TryGetProperty("s", out var active) && active.ValueKind == JsonValueKind.False) return;

            if (!sensor.TryGetProperty("a", out var activated)
                || activated.ValueKind != JsonValueKind.Number
                || !activated.TryGetInt64(out var seconds)
                || seconds is < 1_000_000_000 or > 4_000_000_000) // from 2001 to 2096: anything else is not a date
            {
                return;
            }

            var at = DateTimeOffset.FromUnixTimeSeconds(seconds);
            if (newest is null || at > newest) newest = at;
        }

        if (data.TryGetProperty("activeSensors", out var list) && list.ValueKind == JsonValueKind.Array)
        {
            foreach (var entry in list.EnumerateArray())
            {
                if (entry.ValueKind == JsonValueKind.Object && entry.TryGetProperty("sensor", out var sensor)) Consider(sensor);
            }
        }

        // The same information also appears on the connection, for answers that carry no list.
        if (newest is null && data.TryGetProperty("connection", out var connection)
            && connection.ValueKind == JsonValueKind.Object && connection.TryGetProperty("sensor", out var fallback))
        {
            Consider(fallback);
        }

        return newest is { } found ? new SensorInfo(found) : null;
    }

    /// <summary>
    /// The API reports its own status in the body. 0 is success and 2 (bad credentials) is handled by the caller; any
    /// other value, such as the one used to say that the client version is too old, means the service has changed.
    /// </summary>
    private static void ThrowIfUnexpectedStatus(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new ServiceChangedException("the response is not a JSON object");
        }

        if (!root.TryGetProperty("status", out var status)
            || status.ValueKind != JsonValueKind.Number
            || !status.TryGetInt32(out var code)
            || code == 0)
        {
            return;
        }

        string? minimumVersion = null;
        if (root.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Object
            && data.TryGetProperty("minimumVersion", out var minimum) && minimum.ValueKind != JsonValueKind.Null)
        {
            minimumVersion = minimum.ToString();
        }

        throw new ServiceChangedException(minimumVersion is null
            ? $"status {code}"
            : $"status {code}, the service now asks for app version {minimumVersion} or newer");
    }

    private async Task<JsonDocument> GetAsync(string path, CancellationToken ct)
    {
        if (_token is null) throw new SessionExpiredException();

        using var request = CreateRequest(HttpMethod.Get, path, authenticated: true);
        using var response = await _http.SendAsync(request, ct).ConfigureAwait(false);

        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
        {
            _token = null;
            throw new SessionExpiredException();
        }

        return await ReadJsonAsync(response, ct).ConfigureAwait(false);
    }

    private HttpRequestMessage CreateRequest(HttpMethod method, string path, bool authenticated)
    {
        var request = new HttpRequestMessage(method, _baseUrl + path);
        request.Headers.TryAddWithoutValidation("product", _options.Product);
        request.Headers.TryAddWithoutValidation("version", _options.AppVersion);
        request.Headers.TryAddWithoutValidation("User-Agent", _options.UserAgent);
        request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true };

        if (authenticated)
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _token);
            request.Headers.TryAddWithoutValidation("account-id", _accountIdHash);
        }

        return request;
    }

    private static async Task<JsonDocument> ReadJsonAsync(HttpResponseMessage response, CancellationToken ct)
    {
        if (!response.IsSuccessStatusCode && response.StatusCode != HttpStatusCode.BadRequest)
        {
            var code = (int)response.StatusCode;

            // Forbidden (a blocked client), not found or gone (a removed endpoint) are not hiccups: the service has
            // changed. Server errors and rate limits are, so those stay ordinary, retryable failures.
            if (code is 403 or 404 or 410) throw new ServiceChangedException($"HTTP {code}");
            throw new LibreLinkUpException($"LibreLinkUp returned HTTP {code}.");
        }

        try
        {
            var stream = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            return await JsonDocument.ParseAsync(stream, cancellationToken: ct).ConfigureAwait(false);
        }
        catch (JsonException ex)
        {
            // A web page where JSON was expected is typically a block or challenge page.
            throw new ServiceChangedException("the response is not valid JSON", ex);
        }
    }

    private static GlucoseReading ParseReading(JsonElement e)
    {
        var timestamp = ParseTimestamp(GetString(e, "FactoryTimestamp"));
        var trend = e.TryGetProperty("TrendArrow", out var arrow) && arrow.ValueKind == JsonValueKind.Number
            && Enum.IsDefined(typeof(Trend), arrow.GetInt32())
            ? (Trend)arrow.GetInt32()
            : Trend.Unknown;

        return new GlucoseReading(
            timestamp,
            GetDouble(e, "ValueInMgPerDl"),
            GetDouble(e, "Value"),
            trend,
            GetBool(e, "isHigh"),
            GetBool(e, "isLow"));
    }

    // FactoryTimestamp is UTC in the API's US-style format, e.g. "10/13/2026 8:45:12 PM".
    private static DateTimeOffset ParseTimestamp(string text)
    {
        if (DateTimeOffset.TryParseExact(text, "M/d/yyyy h:mm:ss tt", CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed))
        {
            return parsed;
        }

        throw new ServiceChangedException($"unrecognised timestamp format '{text}'");
    }

    private static string GetString(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? string.Empty : string.Empty;

    private static double GetDouble(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : 0;

    private static bool GetBool(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;

    private static string Sha256Hex(string value) =>
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    [GeneratedRegex("^[A-Za-z0-9]{2,6}$")]
    private static partial Regex RegionPattern();
}
