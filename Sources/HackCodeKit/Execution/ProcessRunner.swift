import Foundation
import Darwin

public struct ProcessRunRequest: Sendable {
    public var executable: String
    public var arguments: [String]
    public var timeout: TimeInterval
    public var maxOutputBytes: Int
    public var sandbox: SandboxProfile

    public init(executable: String, arguments: [String], timeout: TimeInterval = 30,
                maxOutputBytes: Int = 256 * 1024, sandbox: SandboxProfile) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.sandbox = sandbox
    }
}

public struct ProcessRunResult: Sendable {
    public var exitCode: Int32?
    public var terminatingSignal: Int32?
    public var stdout: String
    public var stderr: String
    public var truncated: Bool
    public var timedOut: Bool
    public var cancelled: Bool
    public var duration: TimeInterval
    public var sandboxed: Bool

    public var succeeded: Bool { exitCode == 0 && !timedOut && !cancelled }
}

/// Abstraction so execution can be tested without launching real processes.
public protocol ProcessRunning: Sendable {
    func run(_ request: ProcessRunRequest, sink: OutputSink) async throws -> ProcessRunResult
}

/// Launches a fixed executable with `posix_spawn`:
/// - no shell, no PATH lookup (absolute executable required), argument array passed verbatim;
/// - minimal environment (no inherited secrets), stdin from /dev/null, all other descriptors closed;
/// - its own process group, so timeouts and cancellation terminate the whole tree;
/// - optional Seatbelt sandbox via /usr/bin/sandbox-exec;
/// - bounded output and wall-clock timeout.
public struct SystemProcessRunner: ProcessRunning {
    public static let sandboxExec = "/usr/bin/sandbox-exec"

    public init() {}

    public func run(_ request: ProcessRunRequest, sink: OutputSink) async throws -> ProcessRunResult {
        guard request.executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: request.executable) else {
            throw HackCodeError.launchFailed("\(request.executable) is not an executable at an absolute path")
        }
        var argv = [request.executable] + request.arguments
        var sandboxed = false
        if let profile = request.sandbox.profileText {
            guard FileManager.default.isExecutableFile(atPath: Self.sandboxExec) else {
                throw HackCodeError.launchFailed("sandbox-exec is unavailable, so the sandboxed operation was not started")
            }
            argv = [Self.sandboxExec, "-p", profile] + argv
            sandboxed = true
        }
        if argv.contains(where: { $0.utf8.contains(0) }) {
            throw HackCodeError.launchFailed("an argument contains a NUL byte")
        }

        let state = RunState(maxBytes: request.maxOutputBytes, sink: sink)
        let start = Date()
        let pid = try Self.spawn(argv: argv, state: state)
        state.setPID(pid)

        // Timeout watchdog.
        let deadline = DispatchTime.now() + request.timeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
            if state.markTimedOutIfRunning() { Self.terminateGroup(pid) }
        }

        let status: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
                Thread.detachNewThread {
                    var st: Int32 = 0
                    while waitpid(pid, &st, 0) == -1 && errno == EINTR {}
                    state.markExited()
                    cont.resume(returning: st)
                }
            }
        } onCancel: {
            if state.markCancelledIfRunning() { Self.terminateGroup(pid) }
        }
        state.waitForReaders(timeout: 2)

        let low = status & 0x7f
        let exitCode: Int32? = low == 0 ? (status >> 8) & 0xff : nil
        let signal: Int32? = low == 0 ? nil : low
        let snapshot = state.snapshot()
        return ProcessRunResult(exitCode: exitCode, terminatingSignal: signal,
                                stdout: snapshot.stdout, stderr: snapshot.stderr,
                                truncated: snapshot.truncated, timedOut: snapshot.timedOut,
                                cancelled: snapshot.cancelled, duration: Date().timeIntervalSince(start),
                                sandboxed: sandboxed)
    }

    // MARK: - Spawn

    static let minimalEnvironment: [String] = {
        var env = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=en_US.UTF-8", "LC_ALL=en_US.UTF-8"]
        env.append("HOME=\(NSHomeDirectory())")
        return env
    }()

    private static func spawn(argv: [String], state: RunState) throws -> pid_t {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw HackCodeError.launchFailed("pipe() failed: \(String(cString: strerror(errno)))") }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw HackCodeError.launchFailed("pipe() failed: \(String(cString: strerror(errno)))")
        }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Own process group; close every descriptor not explicitly set up; reset signal state.
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        posix_spawnattr_setflags(&attr, flags)
        posix_spawnattr_setpgroup(&attr, 0)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attr, &defaults)

        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = minimalEnvironment.map { strdup($0) } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, &attr, cArgs, cEnv)
        close(outPipe[1])
        close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw HackCodeError.launchFailed("\(argv[0]): \(String(cString: strerror(rc)))")
        }
        state.startReader(stdoutFD: outPipe[0], stderrFD: errPipe[0])
        return pid
    }

    static func terminateGroup(_ pid: pid_t) {
        guard pid > 1 else { return }
        killpg(pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            // Escalate if the group is still alive.
            if killpg(pid, 0) == 0 { killpg(pid, SIGKILL) }
        }
    }
}

/// Mutable state shared between the reader thread, the waiter and the watchdog.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private let sink: OutputSink
    private var stdoutData = Data()
    private var stderrData = Data()
    private var truncated = false
    private var timedOut = false
    private var cancelled = false
    private var exited = false
    private var exitTime: Date?
    private var pid: pid_t = 0
    private let readersDone = DispatchSemaphore(value: 0)

    init(maxBytes: Int, sink: OutputSink) {
        self.maxBytes = max(1024, maxBytes)
        self.sink = sink
    }

    func setPID(_ p: pid_t) { lock.withLock { pid = p } }

    func markTimedOutIfRunning() -> Bool {
        lock.withLock {
            guard !exited else { return false }
            timedOut = true
            return true
        }
    }

    func markCancelledIfRunning() -> Bool {
        lock.withLock {
            guard !exited else { return false }
            cancelled = true
            return true
        }
    }

    func markExited() { lock.withLock { exited = true; exitTime = Date() } }

    func waitForReaders(timeout: TimeInterval) { _ = readersDone.wait(timeout: .now() + timeout) }

    func snapshot() -> (stdout: String, stderr: String, truncated: Bool, timedOut: Bool, cancelled: Bool) {
        lock.withLock {
            (String(decoding: stdoutData, as: UTF8.self), String(decoding: stderrData, as: UTF8.self), truncated, timedOut, cancelled)
        }
    }

    /// Single reader thread polling both pipes; stops at EOF or shortly after the child exits
    /// (in case a stray descendant keeps the pipe open).
    func startReader(stdoutFD: Int32, stderrFD: Int32) {
        Thread.detachNewThread { [self] in
            var fds = [pollfd(fd: stdoutFD, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: stderrFD, events: Int16(POLLIN), revents: 0)]
            var open = [true, true]
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while open.contains(true) {
                for i in 0..<2 { fds[i].fd = open[i] ? (i == 0 ? stdoutFD : stderrFD) : -1; fds[i].revents = 0 }
                let n = poll(&fds, 2, 200)
                if n < 0 && errno != EINTR { break }
                for i in 0..<2 where open[i] && fds[i].revents != 0 {
                    let count = read(fds[i].fd, &buffer, buffer.count)
                    if count > 0 {
                        append(Data(buffer[0..<count]), isStdout: i == 0)
                    } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                        open[i] = false
                    }
                }
                let shouldStop: Bool = lock.withLock {
                    if let t = exitTime, Date().timeIntervalSince(t) > 1.0 { return true }
                    return false
                }
                if shouldStop { break }
            }
            close(stdoutFD)
            close(stderrFD)
            readersDone.signal()
        }
    }

    private func append(_ data: Data, isStdout: Bool) {
        var emitText: String?
        var killPID: pid_t = 0
        lock.withLock {
            let total = stdoutData.count + stderrData.count
            let remaining = maxBytes - total
            guard remaining > 0 else {
                if !truncated { truncated = true; killPID = exited ? 0 : pid }
                return
            }
            let slice = data.count > remaining ? data.prefix(remaining) : data
            if data.count > remaining { truncated = true; killPID = exited ? 0 : pid }
            if isStdout { stdoutData.append(slice) } else { stderrData.append(slice) }
            emitText = String(decoding: slice, as: UTF8.self)
        }
        if let emitText { sink.emit(isStdout ? .stdout : .stderr, emitText) }
        // Output limit reached: stop the producer rather than buffering unbounded data.
        if killPID > 1 { SystemProcessRunner.terminateGroup(killPID) }
    }
}
