import SwiftUI
import Observation
import HackCodeKit

/// `/watch` — re-runs one read-only operation on an interval and highlights what changed.
@MainActor
@Observable
final class WatchSession: Identifiable {
    let id = UUID()
    let operationID: String
    let arguments: [String: ArgumentValue]
    let interval: TimeInterval
    let displayCommand: String
    static let maxRuns = 360

    private(set) var runs = 0
    private(set) var output = ""
    private(set) var changed: Set<Int> = []
    private(set) var removed = 0
    private(set) var lastStatus: ExecutionStatus?
    private(set) var lastRunAt: Date?
    private(set) var lastChangeRun: Int?
    private(set) var isRunning = false
    private(set) var stopReason: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    let pipeline: OutputPipeline?

    init(operationID: String, arguments: [String: ArgumentValue], interval: TimeInterval, displayCommand: String,
         pipeline: OutputPipeline? = nil) {
        self.operationID = operationID
        self.arguments = arguments
        self.interval = interval
        self.displayCommand = displayCommand
        self.pipeline = pipeline
    }

    func start(app: AppModel) {
        guard !isRunning else { return }
        isRunning = true
        stopReason = nil
        task = Task { [weak self] in
            while let self, !Task.isCancelled, self.runs < Self.maxRuns {
                do {
                    // Every iteration is a fresh, fully validated operation (validated operations are single-use).
                    let op = try app.policy.validate(OperationRequest(operationID: self.operationID, arguments: self.arguments,
                                                                      provenance: .user, rationale: "watch every \(Int(self.interval)) s"))
                    let record = await app.executor.execute(op, approval: nil)
                    guard !Task.isCancelled else { break }
                    self.apply(record)
                } catch {
                    self.stop(reason: error.localizedDescription)
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
            }
            guard let self else { return }
            if self.isRunning { self.stop(reason: self.runs >= Self.maxRuns ? "reached \(Self.maxRuns) runs" : "stopped") }
        }
    }

    func stop(reason: String = "stopped by user") {
        task?.cancel()
        task = nil
        isRunning = false
        stopReason = reason
    }

    private func apply(_ record: ExecutionRecord) {
        let raw = record.output + (record.errorOutput.isEmpty ? "" : "\n" + record.errorOutput)
        let text = pipeline?.apply(raw) ?? raw
        if runs > 0 {
            changed = OutputDiff.changedLines(old: output, new: text)
            removed = OutputDiff.removedLineCount(old: output, new: text)
            if !changed.isEmpty || removed > 0 { lastChangeRun = runs + 1 }
        }
        output = text
        runs += 1
        lastStatus = record.status
        lastRunAt = Date()
    }

    /// Output with changed lines highlighted.
    var highlighted: AttributedString {
        var result = AttributedString()
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            var piece = AttributedString(String(line) + (i < lines.count - 1 ? "\n" : ""))
            if changed.contains(i) {
                piece.foregroundColor = Theme.accent
                piece.backgroundColor = Theme.accent.opacity(0.14)
            } else {
                piece.foregroundColor = Theme.textPrimary.opacity(0.9)
            }
            result += piece
        }
        return result
    }
}

struct WatchBlockView: View {
    let session: WatchSession

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(session.isRunning ? Theme.info : Theme.border).frame(width: 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("watch").font(Theme.Font.bodyStrong).foregroundStyle(Theme.info)
                    Text(session.operationID).font(Theme.Font.bodyStrong).foregroundStyle(Theme.textPrimary)
                    Text("EVERY \(Int(session.interval)) S").font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
                    Text("READ-ONLY").font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(status(now: ctx.date)).font(Theme.Font.micro).monospacedDigit()
                            .foregroundStyle(session.isRunning ? Theme.info : Theme.textTertiary)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("$").font(Theme.Font.bodyStrong).foregroundStyle(Theme.amber)
                    CommandText(command: session.displayCommand)
                    if let p = session.pipeline {
                        Text(p.description).font(Theme.Font.body).foregroundStyle(Theme.info)
                        Text("(local filter)").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                    }
                }
                if session.runs > 1 {
                    Text(changeSummary).font(Theme.Font.caption)
                        .foregroundStyle(session.changed.isEmpty && session.removed == 0 ? Theme.textTertiary : Theme.accent)
                }
                ScrollView {
                    Text(session.output.isEmpty ? "waiting for first run…" : session.highlighted)
                        .font(Theme.Font.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: session.output.count < 2000)
                HStack(spacing: Theme.Space.s) {
                    if session.isRunning {
                        BracketButton("STOP ⌃C", color: Theme.red) { session.stop() }
                    }
                    BracketButton("COPY OUTPUT", color: Theme.textSecondary) { copyToPasteboard(session.output) }
                    Spacer()
                }
            }
            .padding(.leading, Theme.Space.m)
            .padding(.vertical, 6)
        }
        .padding(.leading, 82)
        .background(Color.black.opacity(0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Watching \(session.operationID) every \(Int(session.interval)) seconds")
    }

    private var changeSummary: String {
        if session.changed.isEmpty && session.removed == 0 { return "# no change since previous run" }
        return "# \(session.changed.count) line(s) new or changed, \(session.removed) removed since previous run"
    }

    private func status(now: Date) -> String {
        let last = session.lastRunAt.map { "last \(Int(now.timeIntervalSince($0)))s ago" } ?? "starting"
        if session.isRunning { return "[ ● RUN #\(session.runs) · \(last) ]" }
        return "[ STOPPED · \(session.runs) runs · \(session.stopReason ?? "") ]"
    }
}
