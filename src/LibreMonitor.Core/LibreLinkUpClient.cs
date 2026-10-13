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

            if (root.TryGetProperty("status", out var status) && status.ValueKind == JsonValueKind.Number && status.GetInt32() == 2)
            {
                throw new InvalidCredentialsException();
            }

            if (!root.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Object)
            {
                throw new InvalidCredentialsException();
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
                throw new InvalidCredentialsException();
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
        var patients = new List<Patient>();

        if (doc.RootElement.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in data.EnumerateArray())
            {
                var id = item.GetProperty("patientId").GetString();
                if (id is null) continue;
                patients.Add(new Patient(id, GetString(item, "firstName"), GetString(item, "lastName")));
            }
        }

        return patients;
    }

    public async Task<GlucoseSnapshot> GetGraphAsync(string patientId, CancellationToken ct = default)
    {
        using var doc = await GetAsync($"/llu/connections/{Uri.EscapeDataString(patientId)}/graph", ct).ConfigureAwait(false);

        GlucoseReading? current = null;
        var history = new List<GlucoseReading>();

        if (doc.RootElement.TryGetProperty("data", out var data))
        {
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
        }

        return new GlucoseSnapshot(current, history);
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
            throw new LibreLinkUpException($"LibreLinkUp returned HTTP {(int)response.StatusCode}.");
        }

        try
        {
            var stream = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            return await JsonDocument.ParseAsync(stream, cancellationToken: ct).ConfigureAwait(false);
        }
        catch (JsonException ex)
        {
            throw new LibreLinkUpException("LibreLinkUp returned a response that is not valid JSON.", ex);
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

        throw new LibreLinkUpException($"Unrecognised timestamp format '{text}'.");
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
