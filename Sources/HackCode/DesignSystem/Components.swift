import SwiftUI
import HackCodeKit

/// Thin bordered container used for every panel.
struct Panel<Content: View>: View {
    var padding: CGFloat = Theme.Space.m
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface.opacity(0.78))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: Theme.hairline))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }
}

/// Uppercase, tracked section label: "── PROCESSES".
struct SectionLabel: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(text.uppercased())
                .font(Theme.Font.label)
                .tracking(1.2)
                .foregroundStyle(Theme.textSecondary)
            Rectangle().fill(Theme.border).frame(height: Theme.hairline)
            if let trailing {
                Text(trailing).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Small bracketed tag: [ELEVATED]
struct Tag: View {
    let text: String
    let color: Color
    var filled = false

    var body: some View {
        Text(text)
            .font(Theme.Font.micro)
            .tracking(0.8)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(filled ? Theme.background : color)
            .background(filled ? color : color.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(color.opacity(filled ? 0 : 0.55), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .accessibilityLabel(text)
    }
}

struct RiskTag: View {
    let tier: RiskTier
    var body: some View { Tag(text: tier.label, color: Theme.color(for: tier), filled: tier == .critical) }
}

struct SeverityTag: View {
    let severity: Severity
    var body: some View { Tag(text: severity.label, color: Theme.color(for: severity), filled: severity >= .high) }
}

struct StatusDot: View {
    let color: Color
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color.opacity(0.7), radius: 3)
            .opacity(dim ? 0.35 : 1)
            // Discrete once-per-second blink. A repeatForever animation would redraw the window at display
            // refresh rate (measured: ~28% of a core); this costs one tiny update per second.
            .task(id: pulsing) {
                guard pulsing, !reduceMotion else { dim = false; return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    dim.toggle()
                }
            }
            .accessibilityHidden(true)
    }
}

/// Terminal-style button. `.primary` = green outline; `.danger` = red; `.quiet` = text only.
struct TermButtonStyle: ButtonStyle {
    enum Kind { case primary, danger, warning, quiet }
    var kind: Kind = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let color: Color = {
            switch kind {
            case .primary: return Theme.accent
            case .danger: return Theme.red
            case .warning: return Theme.amber
            case .quiet: return Theme.textSecondary
            }
        }()
        configuration.label
            .font(Theme.Font.label)
            .tracking(0.6)
            .padding(.horizontal, kind == .quiet ? 4 : 9)
            .padding(.vertical, 4)
            .foregroundStyle(isEnabled ? color : Theme.textTertiary)
            .background(configuration.isPressed ? color.opacity(0.18) : (kind == .quiet ? .clear : color.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(kind == .quiet ? .clear : (isEnabled ? color.opacity(0.6) : Theme.border), lineWidth: 1))
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == TermButtonStyle {
    static var term: TermButtonStyle { TermButtonStyle() }
    static func term(_ kind: TermButtonStyle.Kind) -> TermButtonStyle { TermButtonStyle(kind: kind) }
}

/// Horizontal usage meter.
struct Meter: View {
    let fraction: Double?
    var color: Color? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.border)
                if let f = fraction {
                    Rectangle()
                        .fill(color ?? Theme.pressureColor(f))
                        .frame(width: max(0, min(1, f)) * geo.size.width)
                }
            }
        }
        .frame(height: 3)
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "unavailable")
    }
}

/// Lightweight line chart for bounded history. Gaps (nil) are not drawn.
struct Sparkline: View {
    let values: [Double?]
    var maxValue: Double? = nil
    var color: Color = Theme.accent

    var body: some View {
        Canvas { ctx, size in
            let present = values.compactMap { $0 }
            guard values.count > 1, !present.isEmpty else { return }
            let top = max(maxValue ?? (present.max() ?? 1), 0.0001)
            let step = size.width / CGFloat(values.count - 1)
            var path = Path()
            var started = false
            for (i, v) in values.enumerated() {
                guard let v else { started = false; continue }
                let pt = CGPoint(x: CGFloat(i) * step, y: size.height - CGFloat(min(v / top, 1)) * (size.height - 1))
                if started { path.addLine(to: pt) } else { path.move(to: pt); started = true }
            }
            var fill = path
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            ctx.fill(fill, with: .color(color.opacity(0.07)))
            ctx.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

/// Faint CRT scanlines. Purely decorative and disabled when Reduce Transparency is on.
struct Scanlines: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if !reduceTransparency {
            Canvas { ctx, size in
                var y: CGFloat = 0
                while y < size.height {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.white.opacity(0.018)))
                    y += 3
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Block cursor that blinks unless Reduce Motion is enabled.
struct BlinkingCursor: View {
    var color: Color = Theme.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = true

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 7, height: 13)
            .opacity(visible ? 0.9 : 0)
            .task {
                guard !reduceMotion else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 530_000_000)
                    visible.toggle()
                }
            }
            .accessibilityHidden(true)
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var valueColor: Color = Theme.textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(key.uppercased())
                .font(Theme.Font.micro)
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(Theme.Font.caption)
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Compact empty / unavailable / error state. Deliberately small — no oversized illustrations.
struct InlineState: View {
    enum Kind { case empty, loading, unavailable, error }
    let kind: Kind
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Group {
                switch kind {
                case .loading: ProgressView().controlSize(.small)
                case .empty: Text("○").foregroundStyle(Theme.textTertiary)
                case .unavailable: Text("◌").foregroundStyle(Theme.amber)
                case .error: Text("✕").foregroundStyle(Theme.red)
                }
            }
            .font(Theme.Font.body)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.bodyStrong).foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Highlights an argv-style command: executable green, flags grey, everything else white.
struct CommandText: View {
    let command: String

    var body: some View {
        Text(Self.highlight(command))
            .font(Theme.Font.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func highlight(_ command: String) -> AttributedString {
        var out = AttributedString()
        var first = true
        for (i, token) in command.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            if i > 0 { out += AttributedString(" ") }
            var piece = AttributedString(String(token))
            if first && !token.isEmpty {
                piece.foregroundColor = token.hasPrefix("[") ? Theme.textTertiary : Theme.accent
                if !token.hasPrefix("[") { first = false }
            } else if token.hasPrefix("-") {
                piece.foregroundColor = Theme.textSecondary
            } else if token.hasPrefix("/") || token.hasPrefix("~") || token.hasPrefix("'") {
                piece.foregroundColor = Theme.textPrimary
            } else if token.contains("=") {
                piece.foregroundColor = Theme.info
            } else {
                piece.foregroundColor = Theme.textPrimary
            }
            out += piece
        }
        return out
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

extension TimeInterval {
    var elapsedString: String {
        self < 1 ? String(format: "%.0f ms", self * 1000) : (self < 60 ? String(format: "%.1f s", self) : String(format: "%d:%02d", Int(self) / 60, Int(self) % 60))
    }
}

/// Renders model text with inline markdown (bold, code) while preserving line breaks. Links are not made clickable.
struct ModelText: View {
    let text: String

    var body: some View {
        Text(Self.render(text))
            .font(Theme.Font.body)
            .foregroundStyle(Theme.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func render(_ text: String) -> AttributedString {
        let cleaned = text.replacingOccurrences(of: "\n#+ ", with: "\n", options: .regularExpression)
        guard var attributed = try? AttributedString(markdown: cleaned, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        for run in attributed.runs where run.link != nil { attributed[run.range].link = nil }
        return attributed
    }
}

/// Presents a save panel and writes UTF-8 text. Returns false if cancelled or the write failed.
@MainActor
@discardableResult
func saveTextFile(_ text: String, suggestedName: String) -> Bool {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = suggestedName
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return false }
    do {
        try text.write(to: url, atomically: true, encoding: .utf8)
        return true
    } catch {
        return false
    }
}

func timestampForFile() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd-HHmm"
    return f.string(from: Date())
}


/// Highlights case-insensitive occurrences of `query` in `text` (used by ⌘F find).
func highlighted(_ text: String, query: String, base: Color) -> AttributedString {
    var out = AttributedString(text)
    out.foregroundColor = base
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return out }
    var searchStart = out.startIndex
    while searchStart < out.endIndex, let range = out[searchStart...].range(of: q, options: .caseInsensitive) {
        out[range].backgroundColor = Theme.amber.opacity(0.45)
        out[range].foregroundColor = Color.white
        searchStart = range.upperBound
    }
    return out
}
