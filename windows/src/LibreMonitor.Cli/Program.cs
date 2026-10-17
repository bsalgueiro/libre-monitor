using System.Text.Json;
using LibreMonitor.Core;

// Read-only check of the LibreLinkUp connection: logs in as a follower, lists who you follow,
// and prints the latest reading plus the most recent history.
//
// Credentials come from LIBRE_EMAIL / LIBRE_PASSWORD, or are asked for interactively.
// The password is never echoed or written anywhere.
//
// With --sensor it instead prints the shape of what the service reports about the sensor (field names and types, with
// serial numbers and other text replaced by their length, and no glucose values), so it is safe to share.

var email = Environment.GetEnvironmentVariable("LIBRE_EMAIL") ?? Prompt("LibreLinkUp follower email: ");
var password = Environment.GetEnvironmentVariable("LIBRE_PASSWORD") ?? PromptSecret("Password: ");

using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
var client = new LibreLinkUpClient(http);

try
{
    await client.LoginAsync(email, password);
    Console.WriteLine($"Logged in ({client.BaseUrl}).");

    var patients = await client.GetPatientsAsync();
    if (patients.Count == 0)
    {
        Console.WriteLine("This account is not following anyone yet. Invite it from LibreLink > Connected apps > LibreLinkUp.");
        return 0;
    }

    if (args.Contains("--sensor"))
    {
        await PrintSensorShapeAsync(client, patients);
        return 0;
    }

    foreach (var patient in patients)
    {
        var snapshot = await client.GetGraphAsync(patient.PatientId);
        Console.WriteLine($"\n{patient.FirstName} {patient.LastName}");

        if (snapshot.Current is { } now)
        {
            Console.WriteLine($"  Now: {now.MgPerDl:0} mg/dL {now.Trend.ToArrow()}  ({now.TimestampUtc.ToLocalTime():g})");
        }
        else
        {
            Console.WriteLine("  No current reading (sensor warming up or out of range).");
        }

        foreach (var reading in snapshot.History.TakeLast(6))
        {
            Console.WriteLine($"  {reading.TimestampUtc.ToLocalTime():HH:mm}  {reading.MgPerDl:0} mg/dL");
        }
    }

    return 0;
}
catch (LibreLinkUpException ex)
{
    Console.Error.WriteLine(ex.Message);
    return 1;
}

static async Task PrintSensorShapeAsync(LibreLinkUpClient client, IReadOnlyList<Patient> patients)
{
    Console.WriteLine("\nShape of the sensor fields (text is replaced by its length; no glucose values are printed).");

    using (var connections = await client.GetConnectionsDocumentAsync())
    {
        var index = 0;
        foreach (var item in connections.RootElement.GetProperty("data").EnumerateArray())
        {
            Console.WriteLine($"\nconnections[{index++}] keys: {Keys(item)}");
            foreach (var name in new[] { "sensor", "patientDevice" })
            {
                if (item.TryGetProperty(name, out var part)) PrintFields($"connections[].{name}", part);
            }
        }
    }

    foreach (var patient in patients)
    {
        using var graph = await client.GetGraphDocumentAsync(patient.PatientId);
        var data = graph.RootElement.GetProperty("data");
        Console.WriteLine($"\ngraph data keys: {Keys(data)}");
        if (data.TryGetProperty("connection", out var connection)) Console.WriteLine($"graph data.connection keys: {Keys(connection)}");

        if (!data.TryGetProperty("activeSensors", out var sensors) || sensors.ValueKind != JsonValueKind.Array)
        {
            Console.WriteLine("graph data has no activeSensors list.");
            continue;
        }

        var n = 0;
        foreach (var entry in sensors.EnumerateArray())
        {
            Console.WriteLine($"activeSensors[{n}] keys: {Keys(entry)}");
            foreach (var name in new[] { "sensor", "device" })
            {
                if (entry.TryGetProperty(name, out var part)) PrintFields($"activeSensors[{n}].{name}", part);
            }

            n++;
        }
    }
}

static string Keys(JsonElement element) =>
    element.ValueKind == JsonValueKind.Object ? string.Join(", ", element.EnumerateObject().Select(p => p.Name)) : element.ValueKind.ToString();

static void PrintFields(string label, JsonElement element)
{
    Console.WriteLine($"{label}:");
    if (element.ValueKind != JsonValueKind.Object)
    {
        Console.WriteLine($"  ({element.ValueKind})");
        return;
    }

    foreach (var property in element.EnumerateObject())
    {
        var value = property.Value;
        var shown = value.ValueKind switch
        {
            JsonValueKind.String => $"text, {value.GetString()!.Length} characters",
            JsonValueKind.Number => $"number {value.GetRawText()}",
            JsonValueKind.True or JsonValueKind.False => $"boolean {value.GetRawText()}",
            JsonValueKind.Object => $"object with keys: {Keys(value)}",
            JsonValueKind.Array => $"list of {value.GetArrayLength()}",
            _ => value.ValueKind.ToString(),
        };

        // The activation time is the field we hope to use, so show it as a date as well.
        if (property.Name == "a" && value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var seconds))
        {
            shown += $"  (as a date: {DateTimeOffset.FromUnixTimeSeconds(seconds).UtcDateTime:yyyy-MM-dd HH:mm} UTC)";
        }

        Console.WriteLine($"  {property.Name}: {shown}");
    }
}

static string Prompt(string text)
{
    Console.Write(text);
    return Console.ReadLine() ?? string.Empty;
}

static string PromptSecret(string text)
{
    Console.Write(text);
    var buffer = new System.Text.StringBuilder();
    while (Console.ReadKey(intercept: true) is var key && key.Key != ConsoleKey.Enter)
    {
        if (key.Key == ConsoleKey.Backspace && buffer.Length > 0) buffer.Length--;
        else if (!char.IsControl(key.KeyChar)) buffer.Append(key.KeyChar);
    }
    Console.WriteLine();
    return buffer.ToString();
}
