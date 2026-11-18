import Foundation
@testable import HackCodeKit

/// Records process requests and returns canned results; never launches anything.
final class MockRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [ProcessRunRequest] = []
    var handler: @Sendable (ProcessRunRequest) throws -> ProcessRunResult

    init(_ handler: @escaping @Sendable (ProcessRunRequest) throws -> ProcessRunResult = { _ in MockRunner.ok("") }) {
        self.handler = handler
    }

    func run(_ request: ProcessRunRequest, sink: OutputSink) async throws -> ProcessRunResult {
        lock.withLock { requests.append(request) }
        let r = try handler(request)
        if !r.stdout.isEmpty { sink.emit(.stdout, r.stdout) }
        return r
    }

    var requestCount: Int { lock.withLock { requests.count } }

    static func ok(_ out: String, stderr: String = "", exit: Int32 = 0) -> ProcessRunResult {
        ProcessRunResult(exitCode: exit, terminatingSignal: nil, stdout: out, stderr: stderr, truncated: false,
                         timedOut: false, cancelled: false, duration: 0.01, sandboxed: true)
    }
}

final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Reply { let status: Int; let body: String; var headers: [String: String] = [:] }
    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var sent: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    var sentCount: Int { lock.withLock { sent.count } }
    var lastRequest: URLRequest? { lock.withLock { sent.last } }

    private func next(_ request: URLRequest) -> Reply {
        lock.withLock {
            sent.append(request)
            return replies.isEmpty ? Reply(status: 500, body: "{}") : replies.removeFirst()
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let r = next(request)
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        return (Data(r.body.utf8), http)
    }

    func lines(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        let r = next(request)
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        let lines = r.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return (http, AsyncThrowingStream { c in lines.forEach { c.yield($0) }; c.finish() })
    }

    static func chat(_ content: String) -> Reply {
        let escaped = String(data: try! JSONSerialization.data(withJSONObject: [content], options: [.fragmentsAllowed]), encoding: .utf8)!
        let inner = String(escaped.dropFirst().dropLast())
        return Reply(status: 200, body: #"{"choices":[{"index":0,"message":{"role":"assistant","content":\#(inner)},"finish_reason":"stop"}]}"#)
    }
}

/// Temporary directory sandbox for filesystem tests.
struct TempTree {
    let root: String
    init() throws {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("hackcode-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = PathPolicy.realpathOrNil(base)!
    }
    func path(_ rel: String) -> String { (root as NSString).appendingPathComponent(rel) }
    func mkdir(_ rel: String) throws { try FileManager.default.createDirectory(atPath: path(rel), withIntermediateDirectories: true) }
    func write(_ rel: String, _ text: String = "x") throws { try text.write(toFile: path(rel), atomically: true, encoding: .utf8) }
    func symlink(_ rel: String, to dest: String) throws { try FileManager.default.createSymbolicLink(atPath: path(rel), withDestinationPath: dest) }
    func cleanup() { try? FileManager.default.removeItem(atPath: root) }
}

func makeAuditService(runner: ProcessRunning = MockRunner()) -> SecurityAuditService {
    SecurityAuditService(registry: .standard(), runner: runner, auditLog: AuditLogService(fileURL: nil))
}

func makeRegistry(runner: ProcessRunning = MockRunner()) -> OperationRegistry {
    OperationRegistry.standard(OperationDependencies(sampler: ProcessSampler(runner: runner), audit: makeAuditService(runner: runner)))
}

func makePolicy(tree: TempTree? = nil, runner: ProcessRunning = MockRunner()) -> ExecutionPolicy {
    let paths: PathPolicy
    if let tree {
        paths = PathPolicy(readRoots: [tree.path("read")], writeRoots: [tree.path("read/Downloads")], deniedPrefixes: [tree.path("read/secret")])
    } else {
        paths = .standard()
    }
    return ExecutionPolicy(registry: makeRegistry(runner: runner), paths: paths)
}
