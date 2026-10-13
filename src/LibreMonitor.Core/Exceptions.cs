namespace LibreMonitor.Core;

public class LibreLinkUpException : Exception
{
    public LibreLinkUpException(string message, Exception? inner = null) : base(message, inner) { }
}

/// <summary>Wrong email or password.</summary>
public sealed class InvalidCredentialsException : LibreLinkUpException
{
    public InvalidCredentialsException() : base("Invalid LibreLinkUp email or password.") { }
}

/// <summary>The account must complete a step in the official LibreLinkUp app before the API will work.</summary>
public sealed class AccountActionRequiredException : LibreLinkUpException
{
    public string Step { get; }

    public AccountActionRequiredException(string step)
        : base($"LibreLinkUp requires an action before login ({Describe(step)}). Open the official LibreLinkUp app with this account and complete it.")
    {
        Step = step;
    }

    private static string Describe(string step) => step switch
    {
        "tou" => "accept the terms of use",
        "pp" => "accept the privacy policy",
        "verifyEmail" => "verify the email address",
        _ => $"step '{step}'",
    };
}

/// <summary>The session token is missing or no longer accepted; log in again.</summary>
public sealed class SessionExpiredException : LibreLinkUpException
{
    public SessionExpiredException() : base("The LibreLinkUp session is missing or expired. Log in again.") { }
}
