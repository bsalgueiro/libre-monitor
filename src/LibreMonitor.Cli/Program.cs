using LibreMonitor.Core;

// Read-only check of the LibreLinkUp connection: logs in as a follower, lists who you follow,
// and prints the latest reading plus the most recent history.
//
// Credentials come from LIBRE_EMAIL / LIBRE_PASSWORD, or are asked for interactively.
// The password is never echoed or written anywhere.

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
