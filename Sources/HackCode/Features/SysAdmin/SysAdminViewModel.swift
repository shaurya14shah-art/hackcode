import SwiftUI
import Observation
import HackCodeKit

/// One proposed / executed operation in the terminal, observed live by its row.
@MainActor
@Observable
final class OperationBlock: Identifiable {
    enum Phase: Equatable { case pending, running, finished, denied }

    let id = UUID()
    let operation: ValidatedOperation
    let request: String
    var phase: Phase = .pending
    var liveOutput = ""
    var liveTruncated = false
    var record: ExecutionRecord?
    var startedAt: Date?
    var explanation = ""
    var isExplaining = false
    var explainError: String?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var explainTask: Task<Void, Never>?

    static let maxLiveOutput = 200_000

    /// Local `| grep …` filters applied to the displayed output (never executed).
    let pipeline: OutputPipeline?

    init(operation: ValidatedOperation, request: String, pipeline: OutputPipeline? = nil) {
        self.operation = operation
        self.request = request
        self.pipeline = pipeline
    }

    /// Output as displayed (pipeline applied).
    func displayed(_ raw: String) -> String { pipeline?.apply(raw) ?? raw }

    func appendLive(_ text: String) {
        guard !liveTruncated else { return }
        liveOutput += text
        if liveOutput.utf8.count > Self.maxLiveOutput {
            liveOutput = String(liveOutput.prefix(Self.maxLiveOutput))
            liveTruncated = true
        }
    }
}

struct PlanInfo {
    let intent: String
    let approach: String
    let limitations: [String]
    let rejections: [(id: String, reason: String)]
    let contextDisclosure: String
    let modelID: String
    let latency: TimeInterval
}

enum NoticeLevel { case info, warning }

struct TerminalEntry: Identifiable {
    enum Kind {
        case banner
        case user(String)
        case thinking(started: Date)
        case plan(PlanInfo)
        case answer(String)
        case operation(OperationBlock)
        case notice(NoticeLevel, String)
        case error(String, detail: String?)
        case table(String)
        case watch(WatchSession)
    }

    let id = UUID()
    let kind: Kind
    let time = Date()
}

@MainActor
@Observable
final class SysAdminViewModel {
    private(set) var entries: [TerminalEntry] = [TerminalEntry(kind: .banner)]
    var input = ""
    private(set) var isThinking = false
    var pendingApproval: OperationBlock?
    var focusRequest = 0
    private(set) var trimmedCount = 0
    var showPalette = false

    // MARK: Slash dropdown state
    var slashCategory: SlashCategory = .all { didSet { slashSelection = 0 } }
    var slashSelection = 0
    /// Esc hides the dropdown until the input changes.
    var slashDismissedFor: String?
    /// Opened with the "/" button even if the input is not a slash command yet.
    var slashForced = false
    @ObservationIgnored private var slashCatalogCache: [SlashCommand]?
    @ObservationIgnored private var lastSlashQuery: String?
    @ObservationIgnored private var activePipeline: OutputPipeline?

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var thinkingTask: Task<Void, Never>?
    /// Shared across tabs; see SharedHistory.
    private var history: CommandHistory { app?.sharedHistory.history ?? CommandHistory() }
    var historyCount: Int { history.entries.count }

    // MARK: Tab identity
    let conversationID: String
    let tabNumber: Int
    init(tabNumber: Int = 1, conversationID: String = "main") {
        self.tabNumber = tabNumber
        self.conversationID = conversationID
    }

    /// Tab label: the last thing typed, like a terminal title, or "sys.admin".
    var tabTitle: String {
        for entry in entries.reversed() {
            if case .user(let t) = entry.kind {
                let clean = t.trimmingCharacters(in: .whitespaces)
                return clean.count > 22 ? String(clean.prefix(21)) + "…" : clean
            }
        }
        return "sys.admin"
    }

    var isBusy: Bool { isThinking || hasRunningOperation }
    @ObservationIgnored private var historyIndex: Int?

    // MARK: Find in terminal (⌘F)
    var isFinding = false
    var findQuery = "" { didSet { updateFind() } }
    private(set) var findMatches: [UUID] = []
    private(set) var findIndex = 0
    var findFocusRequest = 0

    var currentFindMatch: UUID? { findMatches.indices.contains(findIndex) ? findMatches[findIndex] : nil }

    func beginFind() {
        isFinding = true
        findFocusRequest += 1
        updateFind()
    }

    func endFind() {
        isFinding = false
        findMatches = []
        focusRequest += 1
    }

    func findNext(_ delta: Int = 1) {
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex + delta + findMatches.count) % findMatches.count
    }

    private func updateFind() {
        let q = findQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard isFinding, !q.isEmpty else { findMatches = []; findIndex = 0; return }
        findMatches = entries.filter { Self.searchableText($0).lowercased().contains(q) }.map(\.id)
        findIndex = max(0, findMatches.count - 1)   // start at the newest match, like a terminal scrollback search
    }

    /// Plain text of an entry, for searching.
    static func searchableText(_ entry: TerminalEntry) -> String {
        switch entry.kind {
        case .banner, .thinking: return ""
        case .user(let t), .answer(let t), .table(let t): return t
        case .notice(_, let t): return t
        case .error(let t, let d): return t + " " + (d ?? "")
        case .plan(let p): return ([p.intent, p.approach] + p.limitations + p.rejections.map { "\($0.id) \($0.reason)" }).joined(separator: "\n")
        case .operation(let b):
            return [b.operation.spec.id, b.operation.displayCommand, b.record?.output ?? b.liveOutput, b.record?.errorOutput ?? "", b.explanation].joined(separator: "\n")
        case .watch(let w): return w.displayCommand + "\n" + w.output
        }
    }

    // MARK: Reverse-i-search (Ctrl+R)
    private(set) var isSearchingHistory = false
    private(set) var searchMatch: (index: Int, line: String)?
    @ObservationIgnored private var inputBeforeSearch = ""

    static let maxEntries = 300
    static let examples = [
        "Show me which processes are using the most CPU",
        "Find the largest files in my Downloads folder",
        "Check whether my Mac firewall is enabled",
        "Why is Finder not responding? Check its recent errors",
        "What is using port 3000 on my Mac?",
        "Audit common macOS security settings",
    ]

    func attach(_ app: AppModel) {
        self.app = app
    }

    var recentSlashCommands: [String] { history.recentSlash }

    private func recordHistory(_ text: String) {
        app?.sharedHistory.record(text)
    }

    func clearHistory() async {
        historyIndex = nil
        await app?.sharedHistory.clear()
    }

    // MARK: Reverse history search

    func beginHistorySearch() {
        if isSearchingHistory {
            // Ctrl+R again: next older match.
            if let m = history.search(input, before: searchMatch?.index) { searchMatch = m }
            return
        }
        inputBeforeSearch = input
        isSearchingHistory = true
        searchMatch = nil
        input = ""
        dismissSlash()
        focusRequest += 1
    }

    func historySearchChanged() {
        guard isSearchingHistory else { return }
        searchMatch = history.search(input)
    }

    /// Return: run the match (like bash). Tab / →: put it on the command line for editing.
    func acceptHistorySearch(run: Bool) {
        guard isSearchingHistory else { return }
        isSearchingHistory = false
        let match = searchMatch?.line
        searchMatch = nil
        input = match ?? inputBeforeSearch
        slashDismissedFor = input
        if run, match != nil { submit() }
    }

    func cancelHistorySearch() {
        guard isSearchingHistory else { return }
        isSearchingHistory = false
        searchMatch = nil
        input = inputBeforeSearch
    }

    /// Ctrl+C: interrupt whatever runs; otherwise discard the current line, like a shell.
    func interrupt() {
        if isSearchingHistory { cancelHistorySearch(); return }
        if isThinking || hasRunningOperation || !activeWatches.isEmpty {
            cancelActive()
            append(.notice(.info, "^C — interrupted."))
        } else if !input.isEmpty {
            append(.user(input + " ^C"))
            input = ""
        }
    }

    // MARK: - Slash dropdown

    /// Built-in command and operation names that aliases may not shadow.
    var reservedAliasNames: Set<String> {
        Set(slashCatalog.map { String($0.id.dropFirst()).components(separatedBy: " ").first ?? "" } + ["run", "alias", "unalias", "runbook"])
    }

    var slashCatalog: [SlashCommand] {
        if let c = slashCatalogCache { return c }
        guard let app else { return [] }
        let built = SlashCommandCatalog.build(registry: app.registry)
        slashCatalogCache = built
        return built
    }

    /// Text after "/" while the command word is being typed (no space yet); nil otherwise.
    var slashQuery: String? {
        guard input.hasPrefix("/"), !input.contains(" ") else { return slashForced && input.isEmpty ? "" : nil }
        return String(input.dropFirst())
    }

    var isSlashVisible: Bool {
        guard let _ = slashQuery else { return false }
        return slashDismissedFor != input
    }

    var slashMatches: [SlashCommand] {
        SlashCommandCatalog.filter(slashCatalog + aliasCommands, query: slashQuery ?? "", category: slashCategory, recent: history.recentSlash)
    }

    var aliasCommands: [SlashCommand] {
        (app?.settings.aliases ?? [:]).sorted { $0.key < $1.key }.map {
            SlashCommand(id: "/\($0.key)", title: "alias", detail: "→ \($0.value)", category: .aliases, syntax: "→ \($0.value)",
                         requiredArguments: [], risk: nil, mode: "ALIAS")
        }
    }

    /// Syntax hint for the command currently being given arguments, e.g. "/files.largest path=<path> limit? depth?".
    var argumentHint: SlashCommand? {
        guard input.hasPrefix("/"), let space = input.firstIndex(of: " ") else { return nil }
        let word = String(input[..<space])
        if word == "/run" {
            let rest = input[input.index(after: space)...].split(separator: " ").first.map(String.init) ?? ""
            return slashCatalog.first { $0.id == "/" + rest }
        }
        return slashCatalog.first { $0.id == word && $0.syntax != nil }
    }

    func toggleSlashPalette() {
        if isSlashVisible {
            dismissSlash()
        } else {
            slashForced = true
            slashDismissedFor = nil
            if !input.hasPrefix("/") { input = "/" }
            focusRequest += 1
        }
    }

    func dismissSlash() {
        slashDismissedFor = input
        slashForced = false
    }

    func moveSlashSelection(_ delta: Int) {
        let count = slashMatches.count
        guard count > 0 else { return }
        slashSelection = (slashSelection + delta + count) % count
    }

    func inputChanged() {
        if slashQuery != lastSlashQuery {
            lastSlashQuery = slashQuery
            slashSelection = 0      // a new filter starts at the top
        }
        if slashDismissedFor != nil && slashDismissedFor != input { slashDismissedFor = nil }
        if !input.hasPrefix("/") { slashForced = false }
        slashSelection = min(slashSelection, max(0, slashMatches.count - 1))
        if slashQuery != nil && slashSelection >= slashMatches.count { slashSelection = 0 }
    }

    /// Accepts the highlighted (or given) command. Commands needing arguments are inserted with their
    /// required `key=` fields; others run immediately, exactly as if typed.
    func acceptSlash(_ command: SlashCommand? = nil) {
        let matches = slashMatches
        guard let cmd = command ?? (matches.indices.contains(slashSelection) ? matches[slashSelection] : nil) else { return }
        slashForced = false
        slashSelection = 0
        if cmd.insertsOnly {
            input = cmd.id + " "
            slashDismissedFor = input
            focusRequest += 1
        } else if !cmd.requiredArguments.isEmpty {
            input = cmd.id + " " + cmd.requiredArguments.map { "\($0)=" }.joined(separator: " ")
            slashDismissedFor = input
            focusRequest += 1
        } else {
            // Execute directly — never back through submit()'s dropdown handling (that could recurse forever).
            input = cmd.id
            submitLine()
        }
    }

    // MARK: - Input

    func submit() {
        // Return while the dropdown is open picks the highlighted command, unless the input is already an exact
        // command (built-in, operation or alias).
        if isSlashVisible, let q = slashQuery, !isExactSlashCommand("/" + q), !slashMatches.isEmpty {
            acceptSlash()
            return
        }
        submitLine()
    }

    private func isExactSlashCommand(_ id: String) -> Bool {
        slashCatalog.contains { $0.id == id } || aliasCommands.contains { $0.id == id }
    }

    /// Runs whatever is on the command line, without dropdown handling.
    private func submitLine() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        slashDismissedFor = nil
        slashForced = false
        input = ""
        recordHistory(text)
        historyIndex = nil
        if text.hasPrefix("/") {
            handleLocalCommand(text)
        } else {
            ask(text)
        }
    }

    func historyUp() {
        let entries = history.entries
        guard !entries.isEmpty else { return }
        let i = max(0, (historyIndex ?? entries.count) - 1)
        historyIndex = i
        input = entries[i]
    }

    func historyDown() {
        let entries = history.entries
        guard let i = historyIndex else { return }
        if i + 1 < entries.count {
            historyIndex = i + 1
            input = entries[i + 1]
        } else {
            historyIndex = nil
            input = ""
        }
    }

    func clear() {
        cancelActive()
        entries = [TerminalEntry(kind: .banner)]
        trimmedCount = 0
        if let app { let id = conversationID; Task { await app.llm.clearHistory(conversation: id) } }
    }

    var activeWatches: [WatchSession] {
        entries.compactMap { if case .watch(let w) = $0.kind, w.isRunning { return w }; return nil }
    }

    func cancelActive() {
        thinkingTask?.cancel()
        activeWatches.forEach { $0.stop(reason: "interrupted") }
        for case .operation(let block) in entries.map(\.kind) where block.phase == .running {
            block.task?.cancel()
        }
    }

    private func append(_ kind: TerminalEntry.Kind) {
        var kind = kind
        if case .table(let t) = kind, let pipeline = activePipeline { kind = .table(pipeline.apply(t)) }
        entries.append(TerminalEntry(kind: kind))
        if isFinding { updateFind() }
        if entries.count > Self.maxEntries {
            let overflow = entries.count - Self.maxEntries
            entries.removeSubrange(1...(overflow))   // keep the banner
            trimmedCount += overflow
        }
    }

    // MARK: - AI flow

    private func ask(_ text: String) {
        append(.user(text))
        askWithoutEcho(text)
    }

    private func askWithoutEcho(_ text: String) {
        guard let app else { return }
        guard app.hasAPIKey else {
            append(.error("No NVIDIA API key is configured.",
                          detail: "Add a key in Settings (⌘,). Local operations still work without AI — type /ops to list them and /run <id> to run one."))
            return
        }
        isThinking = true
        append(.thinking(started: Date()))
        let thinkingID = entries.last?.id
        thinkingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isThinking = false
                self.entries.removeAll { $0.id == thinkingID }
            }
            let started = Date()
            let (context, disclosure) = await self.buildContext(for: text, app: app)
            do {
                let proposal = try await app.llm.propose(request: text, context: context, catalog: app.registry.catalogForModel(),
                                                         conversation: self.conversationID)
                try Task.checkCancellation()
                let validated = ValidatedProposal.validate(proposal, policy: app.policy)
                app.modelStatus = .ok(app.settings.modelID)
                for op in validated.operations {
                    await app.auditLog.record(AuditEvent(kind: .proposalValidated, operation: op.spec.id, risk: op.risk.tier,
                                                         provenance: .model, outcome: "validated",
                                                         detail: "model risk=\(op.claimedRisk ?? "none") local risk=\(op.risk.tier.label)"))
                }
                for r in validated.rejections {
                    await app.auditLog.record(AuditEvent(kind: .proposalRejected, operation: r.proposed.id, provenance: .model,
                                                         outcome: "rejected", detail: r.reason))
                }
                self.entries.removeAll { $0.id == thinkingID }
                self.append(.plan(PlanInfo(intent: proposal.intent, approach: proposal.approach, limitations: proposal.limitations,
                                           rejections: validated.rejections.map { ($0.proposed.id, $0.reason) },
                                           contextDisclosure: disclosure, modelID: app.settings.modelID,
                                           latency: Date().timeIntervalSince(started))))
                if let answer = proposal.answer { self.append(.answer(answer)) }
                for op in validated.operations {
                    self.append(.operation(OperationBlock(operation: op, request: text)))
                }
                if validated.operations.isEmpty && proposal.answer == nil && !validated.rejections.isEmpty {
                    self.append(.notice(.warning, "No proposed operation passed local validation, so nothing can run. Rephrase the request or use /ops."))
                }
            } catch is CancellationError {
                self.append(.notice(.info, "Request cancelled."))
            } catch HackCodeError.cancelled {
                self.append(.notice(.info, "Request cancelled."))
            } catch let error as HackCodeError {
                switch error {
                case .authenticationFailed, .modelUnavailable, .missingCredentials:
                    app.modelStatus = .failed(error.localizedDescription)
                default: break
                }
                self.append(.error(error.localizedDescription, detail: Self.advice(for: error)))
            } catch {
                self.append(.error("Unexpected error.", detail: error.localizedDescription))
            }
        }
    }

    private static func advice(for error: HackCodeError) -> String? {
        switch error {
        case .malformedModelOutput: return "Nothing was executed. Try rephrasing, or run an operation directly with /run."
        case .network, .timeout: return "Local monitoring and /run operations keep working while the model is unreachable."
        case .rateLimited: return "Your request was not retried further to avoid duplicate load. Try again shortly."
        case .modelUnavailable: return "Open Settings (⌘,) › Verify to list the Nemotron models available to your key."
        default: return nil
        }
    }

    /// Gathers only the context relevant to the request, and describes exactly what is sent.
    private func buildContext(for text: String, app: AppModel) async -> (String, String) {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var lines = ["macOS \(os)", "Home folder: ~ (paths use ~)", "Local time: \(Date().formatted(date: .abbreviated, time: .shortened))"]
        var disclosed = ["your request", "macOS version", "operation catalogue"]
        let lowered = text.lowercased()
        let perfWords = ["cpu", "memory", "ram", "process", "slow", "fan", "hot", "lag", "using", "hog", "swap", "consum", "app"]
        if app.settings.shareProcessSnapshotWithModel, perfWords.contains(where: { lowered.contains($0) }) {
            let samples = await app.sampler.sample(includeRestricted: false)
            let top = samples.filter { $0.residentBytes != nil }.sorted { ($0.residentBytes ?? 0) > ($1.residentBytes ?? 0) }.prefix(5)
            if !top.isEmpty {
                lines.append("Largest processes by memory right now: " + top.map { "\($0.name) (pid \($0.pid), \(MonitorObservations.bytes($0.residentBytes ?? 0)))" }.joined(separator: ", "))
                disclosed.append("names + memory of your top 5 processes")
            }
        }
        return (lines.joined(separator: "\n"), "Sent to NVIDIA: " + disclosed.joined(separator: ", "))
    }

    func cancelThinking() { thinkingTask?.cancel() }

    // MARK: - Approval & execution

    func requestRun(_ block: OperationBlock) {
        guard block.phase == .pending else { return }
        if block.operation.requiresConfirmation {
            pendingApproval = block
            if let app {
                Task { await app.auditLog.record(AuditEvent(kind: .approvalRequested, operation: block.operation.spec.id, risk: block.operation.risk.tier,
                                                            provenance: block.operation.provenance, outcome: "awaiting user")) }
            }
        } else {
            execute(block, approval: nil)
        }
    }

    func approvePending() {
        guard let block = pendingApproval else { return }
        pendingApproval = nil
        let approval = ApprovalGate.approve(block.operation)
        if let app {
            Task { await app.auditLog.record(AuditEvent(kind: .approvalGranted, operation: block.operation.spec.id, risk: block.operation.risk.tier,
                                                        provenance: block.operation.provenance, outcome: "granted")) }
        }
        execute(block, approval: approval)
    }

    func denyPending() {
        guard let block = pendingApproval else { return }
        pendingApproval = nil
        deny(block)
    }

    func deny(_ block: OperationBlock) {
        guard block.phase == .pending else { return }
        block.phase = .denied
        if let app {
            Task { await app.auditLog.record(AuditEvent(kind: .approvalDenied, operation: block.operation.spec.id, risk: block.operation.risk.tier,
                                                        provenance: block.operation.provenance, outcome: "denied by user")) }
        }
    }

    func cancel(_ block: OperationBlock) { block.task?.cancel() }

    private func execute(_ block: OperationBlock, approval: Approval?) {
        guard let app else { return }
        block.phase = .running
        block.startedAt = Date()
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(2000))
        let sink = OutputSink { _, text in continuation.yield(text) }
        let consumer = Task { @MainActor in
            for await chunk in stream { block.appendLive(chunk) }
        }
        block.task = Task { [weak self] in
            let record = await app.executor.execute(block.operation, approval: approval, sink: sink)
            continuation.finish()
            await consumer.value
            block.record = record
            block.phase = .finished
            // A state-changing operation (e.g. Move to Trash) may change free space: drop the cached reading.
            if !block.operation.spec.isReadOnly { await app.monitorService.invalidateSlowReadings() }
            // Long operation finished while HackCode is in the background → optional notification.
            if record.duration > 10, !NSApp.isActive {
                app.notify("HackCode · \(record.operationID) \(record.status.rawValue.lowercased())", "Finished in \(record.duration.elapsedString).")
            }
            await app.llm.rememberResult(operationID: record.operationID, status: record.status, summary: String(record.output.prefix(300)),
                                         conversation: self?.conversationID ?? "main")
            if app.settings.autoExplainResults, record.status != .rejected, app.hasAPIKey {
                self?.explain(block)
            }
        }
    }

    func explain(_ block: OperationBlock) {
        guard let app, let record = block.record, !block.isExplaining else { return }
        block.isExplaining = true
        block.explanation = ""
        block.explainError = nil
        let stream = OrderedTextStream { block.explanation += $0 }
        block.explainTask = Task {
            do {
                _ = try await app.llm.explainResult(request: block.request, record: record, conversation: conversationID, onDelta: stream.onDelta)
            } catch {
                block.explainError = error.localizedDescription
            }
            await stream.finish()
            block.isExplaining = false
        }
    }

    // MARK: - Local commands (work without the model)

    private func handleLocalCommand(_ text: String) {
        guard let app else { return }
        // User alias: expand once and submit the result exactly as if it had been typed.
        if let expanded = AliasBook.expand(text, aliases: app.settings.aliases) {
            append(.user(text))
            append(.notice(.info, "alias → \(expanded)"))
            if expanded.hasPrefix("/") { handleLocalCommand(expanded, isExpansion: true) } else { askWithoutEcho(expanded) }
            return
        }
        handleLocalCommand(text, isExpansion: false)
    }

    private func handleLocalCommand(_ fullText: String, isExpansion: Bool) {
        guard let app else { return }
        if !isExpansion { append(.user(fullText)) }   // an alias already echoed what was typed
        // Local pipes: "/cmd args | grep x | head 5" — parsed here, applied to output, never executed.
        // "/alias" stores its whole definition, pipes included.
        let isAliasDefinition = fullText.hasPrefix("/alias ")
        let (text, rawStages) = isAliasDefinition ? (fullText, []) : OutputPipeline.split(fullText)
        do {
            activePipeline = rawStages.isEmpty ? nil : try OutputPipeline.parse(rawStages)
        } catch {
            append(.error(error.localizedDescription, detail: "Pipes filter HackCode's output locally; they never run programs."))
            return
        }
        defer { activePipeline = nil }
        let tokens = Self.tokenize(text)
        let command = tokens.first?.lowercased() ?? ""
        switch command {
        case "/help":
            append(.table("""
            Type a request in plain language — HackCode asks the configured Nemotron model for a plan made of
            registered operations, validates it locally, and runs nothing until you press RUN (⌘↩ runs the newest).

            Local commands (no AI, no network):
              /ops                       list every registered operation with its risk tier
              /run <id> [key=value …]    validate and stage an operation yourself, e.g.
                                         /run files.largest path=~/Downloads limit=10
              /runbooks                  list runbooks (curated read-only diagnostics)
              /runbook <id>              stage every step of a runbook, then RUN ALL
              /watch <op> [k=v] every=N  re-run a read-only operation every N s, highlighting changes
              … | grep [-i] [-v] x | head N | tail N | sort [-rn] | uniq | wc -l
                                         filter any output locally (never executed), e.g. /ops | grep network
              /audit                     run the security audit (⌘⇧R)
              /clear                     clear this session (⌘K)
              /help                      this help

            Keys: ⌘1-3 modules · / commands · ⌃R search history · ↑/↓ history · Tab complete · ⌃C interrupt · ⌃L clear
                  ⌘O operations palette · ⌘L focus · ⌘. cancel · ⌘⇧E export · ⌘, settings
            """))
        case "/clear":
            clear()
        case "/ops":
            let rows = app.registry.ordered.map { spec in
                let params = spec.parameters.map { "\($0.name)\($0.isRequired ? "" : "?")" }.joined(separator: " ")
                return "\(spec.baseRisk.label.padding(toLength: 9, withPad: " ", startingAt: 0)) \(spec.id.padding(toLength: 28, withPad: " ", startingAt: 0)) \(params)"
            }
            append(.table("RISK      OPERATION                    PARAMETERS\n" + rows.joined(separator: "\n")))
        case "/alias":
            if tokens.count == 1 {
                let list = app.settings.aliases.sorted { $0.key < $1.key }.map { "/\($0.key.padding(toLength: 14, withPad: " ", startingAt: 0)) → \($0.value)" }
                append(.table(list.isEmpty ? "No aliases yet. Example: /alias dl /files.largest path=~/Downloads limit=10" : list.joined(separator: "\n")))
            } else {
                let name = tokens[1].hasPrefix("/") ? String(tokens[1].dropFirst()) : tokens[1]
                let expansion = tokens.dropFirst(2).joined(separator: " ")
                do {
                    try AliasBook.validate(name: name, expansion: expansion, reserved: reservedAliasNames, existing: app.settings.aliases)
                    app.update { $0.aliases[name] = expansion }
                    append(.notice(.info, "alias /\(name) → \(expansion)"))
                } catch {
                    append(.error(error.localizedDescription, detail: "Usage: /alias <name> <command or request…>"))
                }
            }
        case "/unalias":
            let name = tokens.count > 1 ? (tokens[1].hasPrefix("/") ? String(tokens[1].dropFirst()) : tokens[1]) : ""
            if app.settings.aliases[name] != nil {
                app.update { $0.aliases[name] = nil }
                append(.notice(.info, "removed alias /\(name)"))
            } else {
                append(.error("No alias named /\(name).", detail: "Type /alias to list aliases."))
            }
        case "/theme":
            let names = TerminalPalette.allCases.map(\.rawValue)
            if tokens.count > 1, let p = TerminalPalette(rawValue: tokens[1].lowercased()) {
                app.update { $0.terminalTheme = p.rawValue }
                append(.notice(.info, "Theme set to \(p.title)."))
            } else {
                append(.table("Themes: " + names.joined(separator: " · ") + "\nUsage: /theme amber"))
            }
        case "/report":
            append(.notice(.info, "Building the system report from local measurements…"))
            Task {
                let md = await app.systemReport()
                if saveTextFile(md, suggestedName: "hackcode-report-\(timestampForFile()).md") {
                    append(.notice(.info, "Report saved (\(md.count) characters)."))
                } else {
                    copyToPasteboard(md)
                    append(.notice(.info, "Save cancelled — the report was copied to the clipboard instead."))
                }
            }
        case "/keys":
            app.showShortcuts = true
        case "/trends":
            append(.table(TrendForecast.textReport(app.trends)))
        case "/recap":
            if let recap = app.lastRecap {
                append(.table(recap.lines.map { ($0.warn ? "[ WARN ] " : "[  OK  ] ") + $0.key.padding(toLength: 9, withPad: " ", startingAt: 0) + $0.text }.joined(separator: "\n")))
            } else {
                append(.notice(.info, "No recap this launch — the previous session was less than 6 hours ago, or there is no trend history yet."))
            }
        case "/monitor":
            app.destination = .monitor
        case "/security":
            app.destination = .securityAudit
        case "/storage":
            app.destination = .storage
            if tokens.count > 1 { app.storage.open(tokens[1]) }
        case "/settings":
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case "/export":
            saveTextFile(transcriptMarkdown(), suggestedName: "hackcode-session-\(timestampForFile()).md")
        case "/history":
            if tokens.count > 1, tokens[1] == "clear" {
                Task { await clearHistory() }
                append(.notice(.info, "Command history cleared (memory and disk)."))
            } else {
                let entries = history.entries.suffix(200)
                let offset = history.entries.count - entries.count
                append(.table(entries.isEmpty ? "No commands yet." : entries.enumerated().map { String(format: "%5d  %@", $0.offset + offset + 1, $0.element) }.joined(separator: "\n")
                              + "\n\n⌃R searches history · /history clear erases it" + (app.settings.persistHistory ? " · saved between launches (redacted)" : " · not saved to disk")))
            }
        case "/runall":
            if pendingWithoutApproval.isEmpty {
                append(.notice(.info, "Nothing staged that can run without approval."))
            } else {
                runAllPending()
            }
        case "/watch":
            startWatch(tokens: Array(tokens.dropFirst()), text: text)
        case "/cancel":
            cancelActive()
            append(.notice(.info, "Cancel requested."))
        case "/explain":
            let last = entries.reversed().compactMap { entry -> OperationBlock? in
                if case .operation(let b) = entry.kind, b.phase == .finished, b.record?.status != .rejected { return b }
                return nil
            }.first
            if let last, app.hasAPIKey {
                explain(last)
                append(.notice(.info, "Explaining \(last.operation.spec.id) — the explanation appears under its output."))
            } else {
                append(.error(app.hasAPIKey ? "No finished operation to explain yet." : "No NVIDIA API key is configured.", detail: nil))
            }
        case "/runbooks":
            append(.table(Runbook.all.map { "\($0.id.padding(toLength: 10, withPad: " ", startingAt: 0)) \($0.title) — \($0.summary)" }.joined(separator: "\n")
                          + "\n\nStage one with /runbook <id>."))
        case "/runbook":
            guard tokens.count >= 2, let book = Runbook.named(tokens[1]) else {
                append(.error("Unknown runbook.", detail: "Available: " + Runbook.all.map(\.id).joined(separator: ", ")))
                return
            }
            runRunbook(book)
        case "/audit":
            app.destination = .securityAudit
            app.security.runAudit()
            append(.notice(.info, "Security audit started in SECURITY AUDIT (⌘3)."))
        case "/run":
            guard tokens.count >= 2 else {
                append(.error("Usage: /run <operation-id> [key=value …]", detail: "Type /ops to see operations."))
                return
            }
            stageRun(opID: tokens[1], argumentTokens: Array(tokens.dropFirst(2)), text: text)
        default:
            // Shorthand: "/files.largest path=~/Downloads" == "/run files.largest path=~/Downloads".
            let opID = String(command.dropFirst())
            if app.registry.spec(for: opID) != nil {
                stageRun(opID: opID, argumentTokens: Array(tokens.dropFirst()), text: text)
            } else {
                append(.error("Unknown command \(command).", detail: "Type / to browse commands, or /help."))
            }
        }
    }

    /// `/watch <op> [key=value …] [every=N]` — read-only operations only, 2…300 s interval.
    private func startWatch(tokens: [String], text: String) {
        guard let app else { return }
        guard let opID = tokens.first.map({ $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }), !opID.contains("=") else {
            append(.error("Usage: /watch <operation> [key=value …] [every=seconds]", detail: "Example: /watch process.top_cpu limit=5 every=3"))
            return
        }
        // Refuse non-repeatable operations before looking at their arguments, so the reason is clear.
        guard let spec = app.registry.spec(for: opID) else {
            append(.error("'\(opID)' is not a registered operation.", detail: "Type / to browse operations.")); return
        }
        guard spec.isReadOnly, spec.baseRisk <= .low else {
            append(.error("\(opID) can't be watched: only read-only operations that need no approval can repeat automatically.", detail: nil))
            return
        }
        var interval: TimeInterval = 5
        var args: [String: ArgumentValue] = [:]
        for pair in tokens.dropFirst() {
            guard let eq = pair.firstIndex(of: "=") else {
                append(.error("Argument '\(pair)' is not in key=value form.", detail: nil)); return
            }
            let key = String(pair[..<eq]), value = String(pair[pair.index(after: eq)...])
            if key == "every" {
                guard let s = Double(value), (2...300).contains(s) else {
                    append(.error("every= must be between 2 and 300 seconds.", detail: nil)); return
                }
                interval = s
            } else {
                args[key] = Int(value).map { .integer($0) } ?? .string(value)
            }
        }
        do {
            let op = try app.policy.validate(OperationRequest(operationID: opID, arguments: args, provenance: .user))
            guard op.spec.isReadOnly, !op.requiresConfirmation, op.risk.tier <= .low else {
                append(.error("\(opID) can't be watched: only read-only operations that need no approval can repeat automatically.", detail: nil))
                return
            }
            let session = WatchSession(operationID: opID, arguments: args, interval: interval, displayCommand: op.displayCommand,
                                       pipeline: activePipeline)
            append(.watch(session))
            session.start(app: app)
        } catch {
            append(.error(error.localizedDescription, detail: "Type / to browse operations and their parameters."))
        }
    }

    private func stageRun(opID: String, argumentTokens: [String], text: String) {
        guard let app else { return }
        var args: [String: ArgumentValue] = [:]
        for pair in argumentTokens {
            guard let eq = pair.firstIndex(of: "=") else {
                append(.error("Argument '\(pair)' is not in key=value form.", detail: "Example: /files.largest path=~/Downloads limit=10"))
                return
            }
            let key = String(pair[..<eq])
            let value = String(pair[pair.index(after: eq)...])
            if value.isEmpty {
                append(.error("Argument '\(key)' has no value.", detail: "Fill in \(key)=… and press Return."))
                return
            }
            args[key] = Int(value).map { .integer($0) } ?? .string(value)
        }
        do {
            let op = try app.policy.validate(OperationRequest(operationID: opID, arguments: args, provenance: .user))
            append(.operation(OperationBlock(operation: op, request: text, pipeline: activePipeline)))
        } catch {
            append(.error(error.localizedDescription, detail: "Type / to browse operations and their parameters."))
        }
    }

    func runRunbook(_ book: Runbook) {
        guard let app else { return }
        append(.notice(.info, "Runbook \(book.title): \(book.steps.count) read-only steps staged. Press RUN ALL or run them one by one."))
        for request in book.requests() {
            do {
                append(.operation(OperationBlock(operation: try app.policy.validate(request), request: "Runbook \(book.id)")))
            } catch {
                append(.error("\(request.operationID): \(error.localizedDescription)", detail: nil))
            }
        }
    }

    /// Operations that may run without further approval (informational / low) and are still pending.
    var pendingWithoutApproval: [OperationBlock] {
        entries.compactMap { if case .operation(let b) = $0.kind, b.phase == .pending, !b.operation.requiresConfirmation { return b }; return nil }
    }

    /// Runs every pending operation that needs no approval, one after another. Approval-gated ones are left for the user.
    func runAllPending() {
        let blocks = pendingWithoutApproval
        guard !blocks.isEmpty else { return }
        Task {
            for b in blocks where b.phase == .pending {
                requestRun(b)
                await b.task?.value
            }
        }
    }

    /// Tab completion for local commands and operation / runbook ids.
    func complete() {
        guard let app else { return }
        let parts = input.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let commands = ["/help", "/ops", "/run", "/runbooks", "/runbook", "/audit", "/clear"]
        var candidates: [String] = []
        var prefix = ""
        if parts.count == 1 {
            prefix = parts[0]
            candidates = commands.filter { $0.hasPrefix(prefix) }
            if candidates.count == 1 { input = candidates[0] + " "; return }
        } else if parts.count == 2, parts[0] == "/run" {
            prefix = parts[1]
            candidates = app.registry.ordered.map(\.id).filter { $0.hasPrefix(prefix) }
            if candidates.count == 1, let spec = app.registry.spec(for: candidates[0]) {
                input = "/run \(spec.id) " + spec.parameters.filter(\.isRequired).map { "\($0.name)=" }.joined(separator: " ")
                return
            }
        } else if parts.count == 2, parts[0] == "/runbook" {
            prefix = parts[1]
            candidates = Runbook.all.map(\.id).filter { $0.hasPrefix(prefix) }
            if candidates.count == 1 { input = "/runbook \(candidates[0])"; return }
        }
        guard candidates.count > 1 else { return }
        // Extend to the longest common prefix and show the options.
        var common = candidates[0]
        for c in candidates.dropFirst() { while !c.hasPrefix(common) { common.removeLast() } }
        if common.count > prefix.count {
            input = (parts.count == 1 ? "" : parts[0] + " ") + common
        } else {
            append(.table(candidates.joined(separator: "   ")))
        }
    }

    func stageFromPalette(_ spec: OperationSpec) {
        showPalette = false
        if spec.parameters.contains(where: \.isRequired) {
            input = "/run \(spec.id) " + spec.parameters.filter(\.isRequired).map { "\($0.name)=" }.joined(separator: " ")
            focusRequest += 1
        } else {
            handleLocalCommand("/run \(spec.id)")
        }
    }

    /// Markdown transcript of the session (secrets redacted; home path shortened).
    func transcriptMarkdown() -> String {
        var s = "# HackCode SYS.ADMIN session\n\nExported \(Date().formatted())\n\n"
        for e in entries {
            switch e.kind {
            case .banner, .thinking: continue
            case .user(let t): s += "## › \(t)\n\n"
            case .plan(let p):
                s += "**Plan:** \(p.intent) — \(p.approach)\n\n"
                p.limitations.forEach { s += "- _\($0)_\n" }
                p.rejections.forEach { s += "- rejected `\($0.id)`: \($0.reason)\n" }
                s += "\n"
            case .answer(let t): s += "\(t)\n\n"
            case .notice(_, let t): s += "> \(t)\n\n"
            case .error(let t, let d): s += "> **Error:** \(t)\(d.map { " — \($0)" } ?? "")\n\n"
            case .table(let t): s += "```\n\(t)\n```\n\n"
            case .watch(let w): s += "**watch** `\(w.displayCommand)` every \(Int(w.interval)) s — \(w.runs) runs\n\n```\n\(String(w.output.prefix(20_000)))\n```\n\n"
            case .operation(let b):
                s += "**\(b.operation.spec.id)** [\(b.operation.risk.tier.label), \(b.operation.provenance.rawValue)]\n\n```\n\(b.operation.displayCommand)\n```\n\n"
                if let r = b.record {
                    s += "Status: \(r.status.rawValue) · \(r.duration.elapsedString)\(r.exitCode.map { " · exit \($0)" } ?? "")\(b.pipeline.map { " · filtered \($0)" } ?? "")\n\n```\n\(String(b.displayed(r.output + (r.errorOutput.isEmpty ? "" : "\n" + r.errorOutput)).prefix(20_000)))\n```\n\n"
                } else {
                    s += "Status: \(b.phase == .denied ? "denied" : "not run")\n\n"
                }
                if !b.explanation.isEmpty { s += "_AI explanation:_ \(b.explanation)\n\n" }
            }
        }
        return Redactor().redact(s)
    }

    /// Splits on spaces, honouring double quotes (for paths with spaces). Used only for local parsing.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for ch in text {
            if ch == "\"" { quoted.toggle(); continue }
            if ch == " " && !quoted {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    var hasRunningOperation: Bool {
        entries.contains {
            switch $0.kind {
            case .operation(let b): return b.phase == .running
            case .watch(let w): return w.isRunning
            default: return false
            }
        }
    }

    /// The newest operation still waiting for a RUN press.
    var newestPending: OperationBlock? {
        for entry in entries.reversed() {
            if case .operation(let b) = entry.kind, b.phase == .pending { return b }
        }
        return nil
    }
}

extension SysAdminViewModel {
    /// Stages an operation requested from another module (e.g. Monitor) for review in the terminal.
    func stage(_ request: OperationRequest, note: String) {
        guard let app else { return }
        // Not typed by the user, so it is shown as a system line rather than a prompt.
        let source = app.destination == .sysAdmin ? "" : "from \(app.destination.rawValue): "
        append(.notice(.info, "↳ \(source)\(note)"))
        do {
            let op = try app.policy.validate(request)
            append(.operation(OperationBlock(operation: op, request: note)))
        } catch {
            append(.error(error.localizedDescription, detail: nil))
        }
        app.destination = .sysAdmin
    }
}
