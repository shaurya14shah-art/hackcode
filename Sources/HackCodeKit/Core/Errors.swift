import Foundation

/// Typed errors shared across HackCode. Messages are plain language and never include secrets.
public enum HackCodeError: Error, Equatable, Sendable, LocalizedError {
    // Credentials / provider
    case missingCredentials
    case credentialStoreFailure(OSStatus)
    case authenticationFailed(status: Int)
    case rateLimited(retryAfter: TimeInterval?)
    case modelUnavailable(model: String)
    case providerError(status: Int, detail: String)
    case network(String)
    case timeout(seconds: TimeInterval)
    case cancelled
    case invalidEndpoint(String)

    // Model output
    case malformedModelOutput(String)
    case unsupportedSchemaVersion(Int)

    // Operation boundary
    case unknownOperation(String)
    case invalidArgument(operation: String, argument: String, reason: String)
    case pathNotPermitted(path: String, reason: String)
    case operationDenied(operation: String, reason: String)
    case approvalRequired(operation: String)
    case alreadyExecuted(operation: String)
    case launchFailed(String)
    case permissionDenied(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "No NVIDIA API key is configured. Add one in Settings (⌘,)."
        case .credentialStoreFailure(let status):
            return "The Keychain rejected the request (OSStatus \(status))."
        case .authenticationFailed(let status):
            return "The NVIDIA API rejected the API key (HTTP \(status)). Check the key in Settings."
        case .rateLimited(let retry):
            if let retry { return "The NVIDIA API is rate limiting requests. Retry in about \(Int(retry.rounded())) s." }
            return "The NVIDIA API is rate limiting requests. Wait a moment and retry."
        case .modelUnavailable(let model):
            return "The model '\(model)' is not available to this API key. Choose another model in Settings."
        case .providerError(let status, let detail):
            return "The NVIDIA API returned HTTP \(status): \(detail)"
        case .network(let detail):
            return "Network error: \(detail)"
        case .timeout(let seconds):
            return seconds > 0 ? "The operation did not finish within \(Int(seconds)) s." : "The operation timed out."
        case .cancelled:
            return "Cancelled."
        case .invalidEndpoint(let detail):
            return "Invalid API endpoint: \(detail)"
        case .malformedModelOutput(let detail):
            return "The model returned a response HackCode could not validate: \(detail)"
        case .unsupportedSchemaVersion(let v):
            return "The model used unsupported response schema version \(v)."
        case .unknownOperation(let id):
            return "'\(id)' is not a registered HackCode operation, so it was rejected."
        case .invalidArgument(let op, let arg, let reason):
            return "Argument '\(arg)' for \(op) was rejected: \(reason)"
        case .pathNotPermitted(let path, let reason):
            return "Access to '\(path)' is not permitted: \(reason)"
        case .operationDenied(let op, let reason):
            return "\(op) was denied: \(reason)"
        case .approvalRequired(let op):
            return "\(op) requires your explicit approval before it can run."
        case .alreadyExecuted(let op):
            return "\(op) has already been executed; propose it again to re-run."
        case .launchFailed(let detail):
            return "The system tool could not be started: \(detail)"
        case .permissionDenied(let detail):
            return "macOS denied access: \(detail)"
        }
    }
}
