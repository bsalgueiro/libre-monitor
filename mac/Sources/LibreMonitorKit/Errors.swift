import Foundation

// Port of src/LibreMonitor.Core/Exceptions.cs

public enum LibreLinkUpError: Error, Equatable, LocalizedError {
    /// Wrong email or password.
    case invalidCredentials

    /// The account must complete a step in the official LibreLinkUp app before the API will work.
    case accountActionRequired(step: String)

    /// The session token is missing or no longer accepted; log in again.
    case sessionExpired

    /// Anything else the service or the response got wrong. The message never contains credentials.
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid LibreLinkUp email or password."
        case .accountActionRequired(let step):
            return "LibreLinkUp requires an action before login (\(Self.describe(step))). "
                + "Open the official LibreLinkUp app with this account and complete it."
        case .sessionExpired:
            return "The LibreLinkUp session is missing or expired. Log in again."
        case .other(let message):
            return message
        }
    }

    private static func describe(_ step: String) -> String {
        switch step {
        case "tou": return "accept the terms of use"
        case "pp": return "accept the privacy policy"
        case "verifyEmail": return "verify the email address"
        default: return "step '\(step)'"
        }
    }
}
