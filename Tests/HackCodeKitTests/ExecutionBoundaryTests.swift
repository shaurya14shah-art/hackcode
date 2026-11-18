import Testing
import Foundation
@testable import HackCodeKit

@Suite("Execution policy & risk")
struct ExecutionPolicyTests {
    let policy = makePolicy()

    func request(_ id: String, _ args: [String: ArgumentValue] = [:]) -> OperationRequest {
        OperationRequest(operationID: id, arguments: args, provenance: .model)
    }

    @Test func unknownAndCaseVariantIdsRejected() {
        for id in ["rm", "shell", "system.overview ", "SYSTEM.OVERVIEW", "system.overview;ls", ""] {
            #expect(throws: HackCodeError.self, "\(id)") { try policy.validate(request(id)) }
        }
    }

    @Test func unexpectedArgumentsRejected() {
        #expect(throws: HackCodeError.self) { try policy.validate(request("system.overview", ["cmd": .string("ls")])) }
    }

    @Test func integerBoundsAndTypesEnforced() {
        #expect(throws: HackCodeError.self) { try policy.validate(request("process.top_cpu", ["limit": .integer(0)])) }
        #expect(throws: HackCodeError.self) { try policy.validate(request("process.top_cpu", ["limit": .integer(10_000)])) }
        #expect(throws: HackCodeError.self) { try policy.validate(request("process.top_cpu", ["limit": .string("5; rm -rf ~")])) }
        #expect(throws: Never.self) { try policy.validate(request("process.top_cpu", ["limit": .integer(5)])) }
    }

    @Test func defaultsAppliedAndInformationalNeedsNoConfirmation() throws {
        let op = try policy.validate(request("process.top_cpu"))
        #expect(op.arguments.int("limit") == 10)
        #expect(op.risk.tier == .informational)
        #expect(!op.requiresConfirmation)
    }

    @Test func shellMetacharactersAndInjectionRejectedInTokens() {
        let payloads = ["Finder; rm -rf ~", "Finder\" OR 1==1 OR process == \"x", "$(whoami)", "`id`", "a|b", "a&&b",
                        "../../etc", "Finder\nrm", "x>y"]
        #expect(throws: HackCodeError.self) { try policy.validate(request("logs.process_errors", ["process": .string(String(repeating: "a", count: 65))])) }
        #expect(throws: HackCodeError.self) { try policy.validate(request("launchd.service_status", ["label": .string(String(repeating: "a", count: 129))])) }
        for p in payloads {
            #expect(throws: HackCodeError.self, "\(p)") { try policy.validate(request("logs.process_errors", ["process": .string(p)])) }
            #expect(throws: HackCodeError.self, "\(p)") { try policy.validate(request("launchd.service_status", ["label": .string(p)])) }
        }
        #expect(throws: Never.self) { try policy.validate(request("logs.process_errors", ["process": .string("Google Chrome Helper (Renderer)")])) }
    }

    @Test func argumentsAreSeparateArgvElements() throws {
        let op = try policy.validate(request("logs.process_errors", ["process": .string("Finder"), "minutes": .integer(5)]))
        #expect(op.displayCommand.hasPrefix("/usr/bin/log show --last 5m"))
        #expect(op.spec.sandbox == .none(reason: "the log tool refuses to run inside a sandbox; it is read-only"))
    }

    @Test func choiceValidation() {
        #expect(throws: HackCodeError.self) { try policy.validate(request("launchd.service_status", ["label": .string("com.apple.Finder"), "domain": .string("root")])) }
        #expect(throws: HackCodeError.self) { try policy.validate(request("security.check", ["check": .string("exploit")])) }
    }

    @Test func privilegedOperationsAreCriticalAndNeedConfirmation() throws {
        let op = try policy.validate(request("security.enable_firewall"))
        #expect(op.risk.tier == .critical)
        #expect(op.requiresConfirmation)
        #expect(op.displayCommand == "[administrator] /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on")
        #expect(throws: HackCodeError.self) { try policy.validate(request("security.enable_firewall", ["state": .string("off")])) }
    }

    @Test func terminateDeniedForSystemAndForeignProcesses() {
        #expect(throws: HackCodeError.self) { try policy.validate(request("process.terminate", ["pid": .integer(1)])) }
        #expect(throws: HackCodeError.self) { try policy.validate(request("process.terminate", ["pid": .integer(Int(getpid()))])) }
        #expect(throws: HackCodeError.self) { try policy.validate(request("process.terminate", ["pid": .integer(999_998)])) }
        // A root-owned process other than launchd.
        if let rootPID = ProcessSampler.allPIDs().first(where: { $0 > 1 && ProcessSampler.owner(of: $0) == 0 }) {
            #expect(throws: HackCodeError.self) { try policy.validate(request("process.terminate", ["pid": .integer(Int(rootPID))])) }
        }
    }

    @Test func terminateOwnChildIsElevatedAndRequiresConfirmation() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        let op = try policy.validate(request("process.terminate", ["pid": .integer(Int(child.processIdentifier))]))
        #expect(op.risk.tier == .elevated)
        #expect(op.requiresConfirmation)
    }
}

@Suite("Path policy")
struct PathPolicyTests {
    @Test func readableWithinRoot() throws {
        let t = try TempTree(); defer { t.cleanup() }
        try t.mkdir("read/a")
        let p = PathPolicy(readRoots: [t.path("read")], writeRoots: [], deniedPrefixes: [t.path("read/secret")])
        #expect(try p.resolveReadable(t.path("read/a")) == t.path("read/a"))
        #expect(try p.resolveReadable(t.path("read")) == t.path("read"))
    }

    @Test func traversalRelativeAndControlCharactersRejected() throws {
        let t = try TempTree(); defer { t.cleanup() }
        try t.mkdir("read/a")
        let p = PathPolicy(readRoots: [t.path("read")], writeRoots: [], deniedPrefixes: [])
        for bad in [t.path("read/a/../../"), "read/a", "./read", t.path("read/a\n"), t.path("read/a\u{0}x"), "", String(repeating: "/a", count: 600)] {
            #expect(throws: HackCodeError.self, "\(bad.debugDescription)") { try p.resolveReadable(bad) }
        }
    }

    @Test func symlinkEscapeRejectedButInternalLinkResolved() throws {
        let t = try TempTree(); defer { t.cleanup() }
        try t.mkdir("read/inside")
        try t.mkdir("outside")
        try t.symlink("read/escape", to: t.path("outside"))
        try t.symlink("read/alias", to: t.path("read/inside"))
        let p = PathPolicy(readRoots: [t.path("read")], writeRoots: [], deniedPrefixes: [])
        #expect(throws: HackCodeError.self) { try p.resolveReadable(t.path("read/escape")) }
        #expect(try p.resolveReadable(t.path("read/alias")) == t.path("read/inside"))
    }

    @Test func deniedPrefixesAndSiblingPrefixTrick() throws {
        let t = try TempTree(); defer { t.cleanup() }
        try t.mkdir("read/secret/keys")
        try t.mkdir("read2")
        let p = PathPolicy(readRoots: [t.path("read")], writeRoots: [], deniedPrefixes: [t.path("read/secret")])
        #expect(throws: HackCodeError.self) { try p.resolveReadable(t.path("read/secret/keys")) }
        // "/x/read2" must not be treated as inside root "/x/read".
        #expect(throws: HackCodeError.self) { try p.resolveReadable(t.path("read2")) }
    }

    @Test func trashRules() throws {
        let t = try TempTree(); defer { t.cleanup() }
        try t.mkdir("read/Downloads/folder")
        try t.write("read/Downloads/file.txt")
        try t.write("read/Downloads/.hidden")
        try t.write("read/other.txt")
        try t.mkdir("outside")
        try t.write("outside/victim.txt")
        try t.symlink("read/Downloads/link", to: t.path("outside/victim.txt"))
        try t.symlink("read/Downloads/escape-dir", to: t.path("outside"))
        let p = PathPolicy(readRoots: [t.path("read")], writeRoots: [t.path("read/Downloads")], deniedPrefixes: [])
        #expect(try p.resolveTrashable(t.path("read/Downloads/file.txt")) == t.path("read/Downloads/file.txt"))
        #expect(try p.resolveTrashable(t.path("read/Downloads/folder")) == t.path("read/Downloads/folder"))
        // A symlink item resolves to the link itself, never to its target.
        #expect(try p.resolveTrashable(t.path("read/Downloads/link")) == t.path("read/Downloads/link"))
        #expect(throws: HackCodeError.self) { try p.resolveTrashable(t.path("read/Downloads")) }            // root itself
        #expect(throws: HackCodeError.self) { try p.resolveTrashable(t.path("read/Downloads/.hidden")) }    // hidden
        #expect(throws: HackCodeError.self) { try p.resolveTrashable(t.path("read/other.txt")) }            // outside write roots
        #expect(throws: HackCodeError.self) { try p.resolveTrashable(t.path("read/Downloads/escape-dir/victim.txt")) } // parent escapes
        #expect(throws: HackCodeError.self) { try p.resolveTrashable(t.path("read/Downloads/missing")) }
    }

    @Test func standardPolicyProtectsCredentials() throws {
        let p = PathPolicy.standard()
        let ssh = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
        if FileManager.default.fileExists(atPath: ssh) {
            #expect(throws: HackCodeError.self) { try p.resolveReadable("~/.ssh") }
        }
        #expect(throws: HackCodeError.self) { try p.resolveReadable("/etc") }
        #expect(throws: HackCodeError.self) { try p.resolveReadable("/System") }
        #expect(throws: HackCodeError.self) { try p.resolveTrashable("~/Library/Preferences") }
    }
}

@Suite("Command executor")
struct CommandExecutorTests {
    func setup(_ tree: TempTree, runner: MockRunner = MockRunner()) -> (CommandExecutor, ExecutionPolicy, AuditLogService) {
        let log = AuditLogService(fileURL: nil)
        let policy = makePolicy(tree: tree)
        return (CommandExecutor(policy: policy, runner: runner, auditLog: log), policy, log)
    }

    @Test func elevatedOperationRequiresMatchingApproval() async throws {
        let t = try TempTree(); defer { t.cleanup() }
        try t.mkdir("read/Downloads")
        try t.write("read/Downloads/a.txt")
        try t.write("read/Downloads/b.txt")
        let (executor, policy, log) = setup(t)
        let a = try policy.validate(OperationRequest(operationID: "files.move_to_trash", arguments: ["path": .string(t.path("read/Downloads/a.txt"))], provenance: .model))
        let b = try policy.validate(OperationRequest(operationID: "files.move_to_trash", arguments: ["path": .string(t.path("read/Downloads/b.txt"))], provenance: .model))

        let none = await executor.execute(a, approval: nil)
        #expect(none.status == .rejected)
        let wrong = await executor.execute(a, approval: ApprovalGate.approve(b))
        #expect(wrong.status == .rejected)
        #expect(FileManager.default.fileExists(atPath: t.path("read/Downloads/a.txt")))

        let events = await log.recent(limit: 10)
        #expect(events.filter { $0.kind == .executionRejected }.count == 2)
    }

    @Test func runsOnceOnly() async throws {
        let t = try TempTree(); defer { t.cleanup() }
        try t.mkdir("read")
        let runner = MockRunner { _ in MockRunner.ok("listening") }
        let (executor, policy, _) = setup(t, runner: runner)
        let op = try policy.validate(OperationRequest(operationID: "network.listening", provenance: .model))
        let first = await executor.execute(op, approval: nil)
        let second = await executor.execute(op, approval: nil)
        #expect(first.status == .succeeded)
        #expect(second.status == .rejected)
        #expect(runner.requestCount == 1)
        #expect(runner.requests[0].executable == "/usr/sbin/lsof")
        #expect(runner.requests[0].sandbox == .readOnlyNoNetwork)
    }

    @Test func pathChangedAfterApprovalIsRejected() async throws {
        let t = try TempTree(); defer { t.cleanup() }
        try t.mkdir("read/data")
        try t.mkdir("outside")
        let runner = MockRunner()
        let (executor, policy, _) = setup(t, runner: runner)
        let op = try policy.validate(OperationRequest(operationID: "files.folder_sizes", arguments: ["path": .string(t.path("read/data"))], provenance: .model))
        // Swap the folder for a symlink pointing outside the allowed root (TOCTOU attempt).
        try FileManager.default.removeItem(atPath: t.path("read/data"))
        try t.symlink("read/data", to: t.path("outside"))
        let record = await executor.execute(op, approval: nil)
        #expect(record.status == .rejected)
        #expect(runner.requestCount == 0)
    }

    @Test func trashWithApprovalMovesItem() async throws {
        let t = try TempTree(); defer { t.cleanup() }
        try t.mkdir("read/Downloads")
        try t.write("read/Downloads/junk-\(UUID().uuidString).txt")
        let file = try FileManager.default.contentsOfDirectory(atPath: t.path("read/Downloads")).first!
        let (executor, policy, _) = setup(t)
        let op = try policy.validate(OperationRequest(operationID: "files.move_to_trash", arguments: ["path": .string(t.path("read/Downloads/\(file)"))], provenance: .user))
        let record = await executor.execute(op, approval: ApprovalGate.approve(op))
        #expect(record.status == .succeeded)
        #expect(!FileManager.default.fileExists(atPath: t.path("read/Downloads/\(file)")))
        // Clean up the test file from the Trash.
        if let trashed = record.output.components(separatedBy: "Now at: ").last?.trimmingCharacters(in: .whitespacesAndNewlines) {
            try? FileManager.default.removeItem(atPath: trashed)
        }
    }

    @Test func recursiveScanSkipsProtectedLocations() async throws {
        let t = try TempTree(); defer { t.cleanup() }
        try t.mkdir("read/secret")
        try t.mkdir("read/public")
        try t.write("read/secret/id_rsa", String(repeating: "k", count: 50_000))
        try t.write("read/public/notes.txt", "hello")
        let (executor, policy, _) = setup(t)
        let op = try policy.validate(OperationRequest(operationID: "files.largest", arguments: ["path": .string(t.path("read"))], provenance: .model))
        let record = await executor.execute(op, approval: nil)
        #expect(record.status == .succeeded)
        #expect(record.output.contains("notes.txt"))
        #expect(!record.output.contains("id_rsa"))
        #expect(record.output.contains("Protected locations skipped: 1"))
    }

    @Test func hostileFolderNameStaysOneArgument() async throws {
        let t = try TempTree(); defer { t.cleanup() }
        let evil = "a b;$(touch PWNED) `id` |cat"
        try t.mkdir("read/\(evil)")
        let log = AuditLogService(fileURL: nil)
        let policy = makePolicy(tree: t)
        let executor = CommandExecutor(policy: policy, runner: SystemProcessRunner(), auditLog: log)
        let op = try policy.validate(OperationRequest(operationID: "files.folder_sizes", arguments: ["path": .string(t.path("read/\(evil)"))], provenance: .model))
        let record = await executor.execute(op, approval: nil)
        #expect(record.status == .succeeded)
        #expect(record.sandboxed)
        #expect(record.output.contains(evil))
        #expect(!FileManager.default.fileExists(atPath: t.path("read/PWNED")))
        #expect(!FileManager.default.fileExists(atPath: "PWNED"))
    }
}
