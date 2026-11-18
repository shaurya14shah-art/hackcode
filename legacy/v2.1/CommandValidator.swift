import Foundation

enum CommandRisk: String {
    case low = "LOW"
    case moderate = "MODERATE"
    case high = "HIGH"
    case blocked = "BLOCKED"
}

struct ValidatedCommand {
    let executable: String
    let arguments: [String]
    let risk: CommandRisk
    let requiresConfirmation: Bool
    let riskReason: String
}

enum CommandValidationError: Error, LocalizedError {
    case emptyCommand
    case blockedExecutable(String)
    case shellInjection(String)
    case unknownExecutable(String)
    
    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "Command is empty or contains only whitespace."
        case .blockedExecutable(let exec):
            return "Execution of '\(exec)' is blocked for security reasons."
        case .shellInjection(let pattern):
            return "Potential shell injection detected: '\(pattern)'."
        case .unknownExecutable(let exec):
            return "Unknown executable: '\(exec)'."
        }
    }
}

typealias CommandError = CommandValidationError

class CommandValidator {
    
    private static let blockedExecutables: Set<String> = [
        "rm", "sudo", "su", "chmod", "chown", "dd", "mkfs", "fdisk", "passwd",
        "shutdown", "reboot", "halt", "kill", "killall", "pkill", "nc", "netcat",
        "curl", "wget", "scp", "sftp", "ssh", "telnet", "ftp",
        "bash", "sh", "zsh", "osascript", "python", "python3", "perl", "ruby" // Scripting runtimes
    ]
    
    private static let highRiskExecutables: Set<String> = [
        "mv", "cp", "ln", "mkdir", "rmdir", "touch", "chflags", "xattr", "defaults",
        "systemsetup", "networksetup", "pmset", "nvram", "kextload", "kextunload",
        "csrutil", "spctl", "fdesetup", "softwareupdate", "installer", "pkgutil",
        "diskutil" // Moved from low risk
    ]
    
    private static let lowRiskExecutables: Set<String> = [
        "ls", "pwd", "cd", "echo", "cat", "less", "more", "head", "tail", "wc",
        "grep", "find", "locate", "which", "whereis", "whoami", "id", "groups",
        "date", "cal", "uptime", "w", "who", "last", "history", "clear",
        "man", "info", "whatis", "apropos", "type", "file", "stat", "du", "df",
        "ps", "top", "htop", "lsof", "netstat", "ifconfig", "ping", "traceroute",
        "nslookup", "dig", "host", "arp", "route",
        "sw_vers", "system_profiler", "uname", "sysctl"
        // "env" removed to prevent execution wrappers
    ]
    
    private static let injectionPatterns = [
        ";", "&&", "||", "|", ">", ">>", "<", "$(", "`", 
        "\n", "\r", "\0", "&", "(", ")" // Added control chars and backgrounding
    ]

    static func validate(_ command: String) -> Result<ValidatedCommand, Error> {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .failure(CommandError.emptyCommand)
        }
        
        let arguments = parseCommand(trimmed)
        guard let rawExecutable = arguments.first else {
            return .failure(CommandError.emptyCommand)
        }
        
        // Extract base filename (e.g. /bin/rm -> rm) and lowercase it to prevent APFS bypass
        let executable = URL(fileURLWithPath: rawExecutable).lastPathComponent.lowercased()
        
        let argList = Array(arguments.dropFirst())
        
        // 1. Check for command injection characters in the RAW command string
        for pattern in injectionPatterns {
            if trimmed.contains(pattern) {
                return .failure(CommandError.shellInjection(pattern))
            }
        }
        
        // 2. Check if the extracted executable is blocked
        if blockedExecutables.contains(executable) {
            return .failure(CommandError.blockedExecutable(executable))
        }
        
        // 3. Check for high risk
        if highRiskExecutables.contains(executable) {
            return .success(ValidatedCommand(
                executable: executable,
                arguments: argList,
                risk: .high,
                requiresConfirmation: true,
                riskReason: "Executable '\(executable)' can modify system state or configuration"
            ))
        }
        
        // 4. Check for low risk
        if lowRiskExecutables.contains(executable) {
            return .success(ValidatedCommand(
                executable: executable,
                arguments: argList,
                risk: .low,
                requiresConfirmation: false, // Auto-execute safe commands
                riskReason: "Read-only or safe information gathering utility"
            ))
        }
        
        // 5. Default fallback (unknown executable)
        return .success(ValidatedCommand(
            executable: executable,
            arguments: argList,
            risk: .moderate,
            requiresConfirmation: true, // Always confirm unknown commands
            riskReason: "Unknown executable '\(executable)'; requires user confirmation"
        ))
    }
    
    private static func parseCommand(_ command: String) -> [String] {
        var components = [String]()
        var currentComponent = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false
        var hasQuotes = false // track if empty quotes were used
        
        for char in command {
            if isEscaped {
                currentComponent.append(char)
                isEscaped = false
            } else if char == "\\" {
                isEscaped = true
            } else if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                hasQuotes = true
            } else if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                hasQuotes = true
            } else if char.isWhitespace && !inSingleQuote && !inDoubleQuote {
                if !currentComponent.isEmpty || hasQuotes {
                    components.append(currentComponent)
                    currentComponent = ""
                    hasQuotes = false
                }
            } else {
                currentComponent.append(char)
            }
        }
        
        if !currentComponent.isEmpty || hasQuotes {
            components.append(currentComponent)
        }
        
        return components
    }
}
