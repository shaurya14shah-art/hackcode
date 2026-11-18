import Foundation

public struct ExecutionResult {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let success: Bool
    
    public init(stdout: String, stderr: String, exitCode: Int32, success: Bool) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.success = success
    }
    
    public var displayOutput: String {
        if !stdout.isEmpty { return stdout }
        if !stderr.isEmpty { return "stderr: \(stderr)" }
        return success ? "Command completed with no output." : "Command failed with exit code \(exitCode)."
    }
}

public class CommandExecutor {
    
    public static func execute(executable: String, arguments: [String]) -> ExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin",
            "LANG": "en_US.UTF-8"
        ]
        
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            env["HOME"] = home
        }
        
        process.environment = env
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        let stdoutQueue = DispatchQueue(label: "CommandExecutor.stdout")
        let stderrQueue = DispatchQueue(label: "CommandExecutor.stderr")
        
        var stdoutData = Data()
        var stderrData = Data()
        
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutQueue.async {
                    stdoutData.append(data)
                }
            } else {
                handle.readabilityHandler = nil
            }
        }
        
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrQueue.async {
                    stderrData.append(data)
                }
            } else {
                handle.readabilityHandler = nil
            }
        }
        
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }
        
        do {
            try process.run()
        } catch {
            return ExecutionResult(stdout: "", stderr: "Failed to run process: \(error.localizedDescription)", exitCode: -1, success: false)
        }
        
        let waitResult = semaphore.wait(timeout: .now() + 30.0)
        
        var timedOut = false
        if waitResult == .timedOut {
            timedOut = true
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 2.0)
        }
        
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        
        var finalStdout = ""
        var finalStderr = ""
        
        stdoutQueue.sync {
            finalStdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        
        stderrQueue.sync {
            finalStderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        
        if timedOut {
            return ExecutionResult(stdout: finalStdout, stderr: "Process timed out after 30 seconds.\n" + finalStderr, exitCode: -1, success: false)
        }
        
        let exitCode = process.terminationStatus
        
        return ExecutionResult(
            stdout: finalStdout,
            stderr: finalStderr,
            exitCode: exitCode,
            success: exitCode == 0
        )
    }
    
    public static func execute(_ commandString: String) -> String {
        let tokens = shellTokenize(commandString)
        guard let executable = tokens.first else {
            return ExecutionResult(stdout: "", stderr: "Empty command string", exitCode: -1, success: false).displayOutput
        }
        let arguments = Array(tokens.dropFirst())
        let result = execute(executable: executable, arguments: arguments)
        return result.displayOutput
    }
    
    /// Tokenizes a command string respecting single/double quotes and backslash escapes.
    private static func shellTokenize(_ command: String) -> [String] {
        var tokens = [String]()
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false
        
        for char in command {
            if escaped {
                current.append(char)
                escaped = false
            } else if char == "\\" && !inSingleQuote {
                escaped = true
            } else if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
            } else if char.isWhitespace && !inSingleQuote && !inDoubleQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        
        if !current.isEmpty {
            tokens.append(current)
        }
        
        return tokens
    }
}
