import Foundation

/// Installed-application inventory with CPU architecture from the Mach-O header (native, read-only).
public enum AppArchitecture: String, Sendable, CaseIterable {
    case universal = "UNIVERSAL", appleSilicon = "APPLE SILICON", intel = "INTEL ONLY"
    /// "#!" launcher: the interpreter decides the architecture.
    case script = "SCRIPT"
    /// Info.plist names an executable that is not there (broken or partially deleted bundle).
    case missing = "NO EXECUTABLE"
    case unknown = "UNKNOWN"

    /// Intel-only apps run through Rosetta 2 on Apple silicon.
    public var needsRosetta: Bool { self == .intel }
}

public struct InstalledApp: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let bundleID: String?
    public let version: String?
    public let architecture: AppArchitecture
    public let modified: Date?
    /// Inside /System or an Apple bundle id.
    public let isApple: Bool
}

public enum AppInventory {
    static let CPU_TYPE_X86_64: UInt32 = 0x0100_0007
    static let CPU_TYPE_ARM64: UInt32 = 0x0100_000C

    /// Architectures in a Mach-O (thin or fat/universal) header. Reads only the first 4 KB.
    public static func architectures(ofHeader data: Data) -> Set<UInt32> {
        guard data.count >= 8 else { return [] }
        func be32(_ o: Int) -> UInt32 { data.count >= o + 4 ? data[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } : 0 }
        func le32(_ o: Int) -> UInt32 { data.count >= o + 4 ? data[o..<o + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } : 0 }
        let magicBE = be32(0)
        switch magicBE {
        case 0xCAFE_BABE, 0xCAFE_BABF:      // FAT_MAGIC / FAT_MAGIC_64 (big-endian)
            let count = Int(be32(4))
            guard count > 0, count < 32 else { return [] }
            let entry = magicBE == 0xCAFE_BABE ? 20 : 32
            return Set((0..<count).compactMap { i in
                let off = 8 + i * entry
                return data.count >= off + 4 ? be32(off) : nil
            })
        default:
            let magicLE = le32(0)
            guard magicLE == 0xFEED_FACF || magicLE == 0xFEED_FACE else { return [] }   // MH_MAGIC_64 / MH_MAGIC
            return [le32(4)]
        }
    }

    public static func classify(_ cpuTypes: Set<UInt32>) -> AppArchitecture {
        let arm = cpuTypes.contains(CPU_TYPE_ARM64), intel = cpuTypes.contains(CPU_TYPE_X86_64)
        switch (arm, intel) {
        case (true, true): return .universal
        case (true, false): return .appleSilicon
        case (false, true): return .intel
        default: return .unknown
        }
    }

    public static let standardFolders: [String] = [
        "/Applications", "/Applications/Utilities", (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
    ]

    /// Scans the top level of each folder for .app bundles (no recursion into bundles, nothing executed).
    public static func scan(folders: [String] = standardFolders) -> [InstalledApp] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [InstalledApp] = []
        for folder in folders {
            guard let names = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            for n in names where n.hasSuffix(".app") {
                let path = (folder as NSString).appendingPathComponent(n)
                let resolved = (path as NSString).resolvingSymlinksInPath
                guard seen.insert(resolved).inserted, let app = inspect(path) else { continue }
                out.append(app)
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func inspect(_ path: String) -> InstalledApp? {
        let contents = (path as NSString).appendingPathComponent("Contents")
        let info = NSDictionary(contentsOfFile: (contents as NSString).appendingPathComponent("Info.plist")) as? [String: Any]
        let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let bundleID = info?["CFBundleIdentifier"] as? String
        var arch = AppArchitecture.unknown
        if let exe = info?["CFBundleExecutable"] as? String {
            let exePath = ((contents as NSString).appendingPathComponent("MacOS") as NSString).appendingPathComponent(exe)
            if let h = FileHandle(forReadingAtPath: exePath) {
                let data = (try? h.read(upToCount: 4096)) ?? Data()
                try? h.close()
                arch = data.starts(with: Data("#!".utf8)) ? .script : classify(architectures(ofHeader: data))
            } else {
                arch = .missing
            }
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        return InstalledApp(name: name, path: path, bundleID: bundleID,
                            version: (info?["CFBundleShortVersionString"] as? String) ?? (info?["CFBundleVersion"] as? String),
                            architecture: arch, modified: modified,
                            isApple: path.hasPrefix("/System/") || (bundleID?.hasPrefix("com.apple.") ?? false))
    }
}
