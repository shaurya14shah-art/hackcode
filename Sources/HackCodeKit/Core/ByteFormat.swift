import Foundation

/// Byte counts that always render as numbers ("0 KB", never Foundation's "Zero KB").
public enum ByteFormat {
    public static func string(_ bytes: Int64, _ style: ByteCountFormatter.CountStyle = .file) -> String {
        let f = ByteCountFormatter()
        f.countStyle = style
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: bytes)
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        string(Int64(max(0, bytesPerSecond).rounded()), .binary) + "/s"
    }
}
