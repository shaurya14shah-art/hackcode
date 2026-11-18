import Testing
import Foundation
@testable import HackCodeKit

/// These tests launch only harmless binaries (echo, sleep, yes, touch, env) inside temporary locations.
@Suite("Process runner", .serialized)
struct ProcessRunnerTests {
    let runner = SystemProcessRunner()

    @Test func capturesOutputAndExitCode() async throws {
        let r = try await runner.run(ProcessRunRequest(executable: "/bin/echo", arguments: ["hello", "$HOME", "; ls"], sandbox: .readOnlyNoNetwork), sink: .discard)
        #expect(r.exitCode == 0)
        #expect(r.stdout == "hello $HOME ; ls\n")
        #expect(r.sandboxed)
    }

    @Test func rejectsRelativeOrMissingExecutables() async {
        await #expect(throws: HackCodeError.self) { try await runner.run(ProcessRunRequest(executable: "echo", arguments: [], sandbox: .readOnlyNoNetwork), sink: .discard) }
        await #expect(throws: HackCodeError.self) { try await runner.run(ProcessRunRequest(executable: "/nonexistent/tool", arguments: [], sandbox: .readOnlyNoNetwork), sink: .discard) }
    }

    @Test func timeoutTerminatesProcess() async throws {
        let start = Date()
        let r = try await runner.run(ProcessRunRequest(executable: "/bin/sleep", arguments: ["20"], timeout: 0.5, sandbox: .readOnlyNoNetwork), sink: .discard)
        #expect(r.timedOut)
        #expect(!r.succeeded)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func cancellationTerminatesProcessTree() async throws {
        let start = Date()
        let task = Task {
            try await runner.run(ProcessRunRequest(executable: "/bin/sh", arguments: ["-c", "/bin/sleep 30 & wait"], timeout: 60,
                                                   sandbox: .readOnlyNoNetwork), sink: .discard)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let r = try await task.value
        #expect(r.cancelled)
        #expect(Date().timeIntervalSince(start) < 6)
    }

    @Test func outputIsBounded() async throws {
        let r = try await runner.run(ProcessRunRequest(executable: "/usr/bin/yes", arguments: [], timeout: 10, maxOutputBytes: 8192,
                                                       sandbox: .readOnlyNoNetwork), sink: .discard)
        #expect(r.truncated)
        #expect(r.stdout.utf8.count <= 8192)
    }

    @Test func sandboxDeniesFileWrites() async throws {
        let target = (NSTemporaryDirectory() as NSString).appendingPathComponent("hackcode-sbx-\(UUID().uuidString)")
        let r = try await runner.run(ProcessRunRequest(executable: "/usr/bin/touch", arguments: [target], sandbox: .readOnlyNoNetwork), sink: .discard)
        #expect(r.exitCode != 0)
        #expect(!FileManager.default.fileExists(atPath: target))
    }

    @Test func sandboxDeniesNetwork() async throws {
        let r = try await runner.run(ProcessRunRequest(executable: "/usr/bin/curl", arguments: ["-s", "-m", "5", "https://example.com"], timeout: 15,
                                                       sandbox: .readOnlyNoNetwork), sink: .discard)
        #expect(r.exitCode != 0)
    }

    @Test func environmentIsScrubbed() async throws {
        setenv("HACKCODE_TEST_SECRET", "s3cr3t-value", 1)
        let r = try await runner.run(ProcessRunRequest(executable: "/usr/bin/env", arguments: [], sandbox: .readOnlyNoNetwork), sink: .discard)
        #expect(!r.stdout.contains("s3cr3t-value"))
        #expect(r.stdout.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
    }

    @Test func streamsOutput() async throws {
        let collected = LockedBox("")
        _ = try await runner.run(ProcessRunRequest(executable: "/bin/echo", arguments: ["streamed"], sandbox: .readOnlyNoNetwork),
                                 sink: OutputSink { _, text in collected.mutate { $0 += text } })
        #expect(collected.value.contains("streamed"))
    }
}

final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T { lock.withLock { _value } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&_value) } }
}
