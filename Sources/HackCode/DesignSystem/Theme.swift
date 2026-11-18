import SwiftUI
import HackCodeKit

/// Central design tokens. Every view uses these; no ad-hoc colours or fonts.
enum Theme {
    // Surfaces
    static let background = Color(red: 0.020, green: 0.024, blue: 0.022)
    static let surface = Color(red: 0.043, green: 0.051, blue: 0.047)
    static let surfaceRaised = Color(red: 0.066, green: 0.078, blue: 0.071)
    static let surfaceHover = Color(red: 0.090, green: 0.106, blue: 0.096)
    static let border = Color(red: 0.115, green: 0.137, blue: 0.122)
    static let borderStrong = Color(red: 0.180, green: 0.215, blue: 0.190)

    // Text
    static let textPrimary = Color(red: 0.902, green: 0.914, blue: 0.906)
    static let textSecondary = Color(red: 0.604, green: 0.635, blue: 0.612)
    static let textTertiary = Color(red: 0.388, green: 0.420, blue: 0.396)

    // Signal colours — accent, warning and info follow the selected terminal palette.
    /// Written only on the main thread (AppModel applies the setting); read during rendering.
    nonisolated(unsafe) static var palette: TerminalPalette = .green
    static var accent: Color { palette.accent }
    static var accentDim: Color { palette.accent.opacity(0.55) }
    static var amber: Color { palette.warning }
    static let red = Color(red: 1.0, green: 0.380, blue: 0.360)
    static var info: Color { palette.info }

    // Spacing
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    static let radius: CGFloat = 3
    static let hairline: CGFloat = 1

    // Typography (SF Mono via the monospaced system design)
    enum Font {
        static let micro = SwiftUI.Font.system(size: 9.5, weight: .semibold, design: .monospaced)
        static let label = SwiftUI.Font.system(size: 10.5, weight: .semibold, design: .monospaced)
        static let caption = SwiftUI.Font.system(size: 11, weight: .regular, design: .monospaced)
        static let body = SwiftUI.Font.system(size: 12.5, weight: .regular, design: .monospaced)
        static let bodyStrong = SwiftUI.Font.system(size: 12.5, weight: .semibold, design: .monospaced)
        static let title = SwiftUI.Font.system(size: 14, weight: .bold, design: .monospaced)
        static let metric = SwiftUI.Font.system(size: 20, weight: .medium, design: .monospaced)
    }

    static func color(for tier: RiskTier) -> Color {
        switch tier {
        case .informational: return accent
        case .low: return info
        case .elevated: return amber
        case .critical: return red
        }
    }

    static func color(for severity: Severity) -> Color {
        switch severity {
        case .info: return textSecondary
        case .low: return info
        case .medium: return amber
        case .high, .critical: return red
        }
    }

    static func color(for status: FindingStatus) -> Color {
        switch status {
        case .pass, .remediated: return accent
        case .issue, .unresolved: return amber
        case .observed: return info
        case .couldNotRun: return textTertiary
        }
    }

    static func color(for status: ExecutionStatus) -> Color {
        switch status {
        case .succeeded: return accent
        case .partial, .timedOut, .cancelled: return amber
        case .failed, .rejected: return red
        }
    }

    static func pressureColor(_ fraction: Double) -> Color {
        fraction > 0.9 ? red : (fraction > 0.7 ? amber : accent)
    }
}

enum Motion {
    static let quick = Animation.easeOut(duration: 0.12)
    static let standard = Animation.easeInOut(duration: 0.2)
}

/// Classic CRT phosphor palettes for the terminal look.
enum TerminalPalette: String, CaseIterable, Identifiable {
    case green, amber, cyan, mono
    var id: String { rawValue }

    var title: String {
        switch self {
        case .green: return "Green phosphor (P1)"
        case .amber: return "Amber phosphor (P3)"
        case .cyan: return "Ice (cyan)"
        case .mono: return "Mono (paper white)"
        }
    }

    var accent: Color {
        switch self {
        case .green: return Color(red: 0.247, green: 0.863, blue: 0.494)
        case .amber: return Color(red: 1.0, green: 0.690, blue: 0.180)
        case .cyan: return Color(red: 0.330, green: 0.850, blue: 0.950)
        case .mono: return Color(red: 0.880, green: 0.900, blue: 0.890)
        }
    }

    /// Warnings must stay distinguishable from the accent.
    var warning: Color {
        switch self {
        case .amber: return Color(red: 1.0, green: 0.450, blue: 0.300)
        default: return Color(red: 0.961, green: 0.690, blue: 0.255)
        }
    }

    var info: Color {
        switch self {
        case .cyan: return Color(red: 0.700, green: 0.640, blue: 1.0)
        default: return Color(red: 0.560, green: 0.760, blue: 0.900)
        }
    }
}
