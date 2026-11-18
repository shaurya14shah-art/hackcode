import Foundation

/// The security boundary between proposals and the operating system.
/// - Executes only `ValidatedOperation`s (which only `ExecutionPolicy` can create).
/// - Re-validates paths and risk immediately before running.
/// - Refuses operations that require confirmation unless a matching `Approval` is supplied.
/// - Runs each validated operation at most once (no duplicate side effects on retry).
/// - Records every attempt in the audit log.
public actor CommandExecutor {
    private let policy: ExecutionPolicy
    private let runner: ProcessRunning
    private let auditLog: AuditLogging
    private var executed = Set<UUID>()

    public init(policy: ExecutionPolicy, runner: ProcessRunning = SystemProcessRunner(), auditLog: AuditLogging) {
        self.policy = policy
        self.runner = runner
        self.auditLog = auditLog
    }

    public func execute(_ operation: ValidatedOperation, approval: Approval?, sink: OutputSink = .discard) async -> ExecutionRecord {
        let started = Date()
        func rejected(_ error: HackCodeError) async -> ExecutionRecord {
            await auditLog.record(.init(kind: .executionRejected, operation: operation.spec.id, risk: operation.risk.tier,
                                        provenance: operation.provenance, outcome: "rejected", detail: error.localizedDescription))
            return ExecutionRecord(id: operation.id, operationID: operation.spec.id, displayCommand: operation.displayCommand,
                                   status: .rejected, exitCode: nil, output: "", errorOutput: error.localizedDescription,
                                   truncated: false, sandboxed: false, startedAt: started, duration: 0)
        }

        guard !executed.contains(operation.id) else { return await rejected(.alreadyExecuted(operation: operation.spec.title)) }
        if operation.requiresConfirmation {
            guard let approval, approval.operationID == operation.id else {
                return await rejected(.approvalRequired(operation: operation.spec.title))
            }
        }
        do {
            try policy.revalidate(operation)
        } catch let error as HackCodeError {
            return await rejected(error)
        } catch {
            return await rejected(.operationDenied(operation: operation.spec.title, reason: error.localizedDescription))
        }
        executed.insert(operation.id)

        await auditLog.record(.init(kind: .executionStarted, operation: operation.spec.id, risk: operation.risk.tier,
                                    provenance: operation.provenance, outcome: "started",
                                    detail: approval == nil ? "no approval required" : "approved by user"))
        let record = await perform(operation, sink: sink, started: started)
        await auditLog.record(.init(kind: .executionFinished, operation: operation.spec.id, risk: operation.risk.tier,
                                    provenance: operation.provenance, outcome: record.status.rawValue,
                                    detail: "exit=\(record.exitCode.map(String.init) ?? "n/a") duration=\(String(format: "%.2f", record.duration))s output=\(record.output.utf8.count)B truncated=\(record.truncated)"))
        return record
    }

    private func perform(_ operation: ValidatedOperation, sink: OutputSink, started: Date) async -> ExecutionRecord {
        let spec = operation.spec
        func record(_ status: ExecutionStatus, exit: Int32? = nil, out: String = "", err: String = "",
                    truncated: Bool = false, sandboxed: Bool = false, note: String? = nil) -> ExecutionRecord {
            ExecutionRecord(id: operation.id, operationID: spec.id, displayCommand: operation.displayCommand, status: status,
                            exitCode: exit, output: out, errorOutput: err, truncated: truncated, sandboxed: sandboxed,
                            startedAt: started, duration: Date().timeIntervalSince(started), note: note)
        }

        switch spec.action {
        case .process(let executable, let sandbox, let build):
            do {
                let args = try build(operation.arguments, policy.context)
                let filter = spec.outputFilter
                let result = try await runner.run(ProcessRunRequest(executable: executable, arguments: args,
                                                                    timeout: spec.timeoutSeconds, maxOutputBytes: spec.maxOutputBytes,
                                                                    sandbox: sandbox), sink: filter == nil ? sink : .discard)
                let out = filter.map { $0(result.stdout) } ?? result.stdout
                return record(Self.status(for: result), exit: result.exitCode, out: out, err: result.stderr,
                              truncated: result.truncated, sandboxed: result.sandboxed, note: Self.note(for: result, spec: spec))
            } catch let error as HackCodeError {
                return record(.failed, err: error.localizedDescription)
            } catch {
                return record(.failed, err: error.localizedDescription)
            }

        case .native(let body):
            do {
                let output = try await withTimeout(seconds: spec.timeoutSeconds) {
                    try await body(operation.arguments, self.policy.context, sink)
                }
                let bounded = Self.bound(spec.outputFilter.map { $0(output) } ?? output, maxBytes: spec.maxOutputBytes)
                return record(bounded.truncated ? .partial : .succeeded, exit: 0, out: bounded.text, truncated: bounded.truncated)
            } catch is CancellationError {
                return record(.cancelled, err: "Cancelled before completion.", note: Self.unknownStateNote(spec))
            } catch HackCodeError.cancelled {
                return record(.cancelled, err: "Cancelled before completion.", note: Self.unknownStateNote(spec))
            } catch HackCodeError.timeout(let s) {
                return record(.timedOut, err: "Timed out after \(Int(s)) s.", note: Self.unknownStateNote(spec))
            } catch {
                return record(.failed, err: error.localizedDescription)
            }

        case .privilegedFixedCommand(let command):
            // The command is a compile-time constant from the registry; nothing from the model or user is interpolated.
            let script = "do shell script \"\(command)\" with administrator privileges"
            do {
                let result = try await runner.run(ProcessRunRequest(executable: "/usr/bin/osascript", arguments: ["-e", script],
                                                                    timeout: spec.timeoutSeconds, maxOutputBytes: spec.maxOutputBytes,
                                                                    sandbox: .none(reason: "administrator command")), sink: sink)
                var note = Self.note(for: result, spec: spec)
                if result.stderr.contains("-128") { note = "You cancelled the macOS administrator prompt. Nothing was changed." }
                return record(Self.status(for: result), exit: result.exitCode, out: result.stdout, err: result.stderr,
                              truncated: result.truncated, sandboxed: false, note: note)
            } catch {
                return record(.failed, err: error.localizedDescription)
            }
        }
    }

    static func status(for result: ProcessRunResult) -> ExecutionStatus {
        if result.cancelled { return .cancelled }
        if result.timedOut { return .timedOut }
        if result.truncated { return .partial }
        return result.exitCode == 0 ? .succeeded : .failed
    }

    static func note(for result: ProcessRunResult, spec: OperationSpec) -> String? {
        if result.truncated { return "Output exceeded \(spec.maxOutputBytes / 1024) KB; the process was stopped and output truncated." }
        if result.timedOut || result.cancelled { return unknownStateNote(spec) }
        return nil
    }

    static func unknownStateNote(_ spec: OperationSpec) -> String? {
        spec.isReadOnly ? nil : "The operation was interrupted; its effect is unknown. Re-inspect the affected item before retrying."
    }

    static func bound(_ text: String, maxBytes: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > maxBytes else { return (text, false) }
        let prefix = String(decoding: Array(text.utf8.prefix(maxBytes)), as: UTF8.self)
        return (prefix, true)
    }
}

/// Runs `body` with a wall-clock limit; throws `HackCodeError.timeout` if it is exceeded.
func withTimeout<T: Sendable>(seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw HackCodeError.timeout(seconds: seconds)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw HackCodeError.cancelled }
        return first
    }
}
