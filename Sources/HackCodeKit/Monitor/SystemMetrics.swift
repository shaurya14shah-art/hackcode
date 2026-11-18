import Foundation
import Darwin

/// A value that may be unavailable, with the reason shown in the UI instead of a fabricated number.
public enum Measured<T: Sendable & Equatable>: Sendable, Equatable {
    case value(T)
    case unavailable(String)

    public var value: T? {
        if case .value(let v) = self { return v }
        return nil
    }
}

public struct CPUTicks: Sendable, Equatable {
    public var user: UInt64, system: UInt64, idle: UInt64, nice: UInt64
    public var total: UInt64 { user + system + idle + nice }
}

public struct CPUUsage: Sendable, Equatable {
    public var user: Double
    public var system: Double
    public var idle: Double
    public var busy: Double { user + system }
}

public struct MemoryStats: Sendable, Equatable {
    public var physicalBytes: UInt64
    public var usedBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    public var appBytes: UInt64
    public var cachedBytes: UInt64
    public var swapUsedBytes: UInt64?
    public var swapTotalBytes: UInt64?
    /// 1 = normal, 2 = warning, 4 = critical (kern.memorystatus_vm_pressure_level).
    public var pressureLevel: Int?

    public var pressureLabel: String {
        switch pressureLevel {
        case 1?: return "NORMAL"
        case 2?: return "WARNING"
        case 4?: return "CRITICAL"
        default: return "UNKNOWN"
        }
    }
}

public struct VolumeStats: Sendable, Equatable, Identifiable {
    public var id: String { mountPoint }
    public var name: String
    public var mountPoint: String
    public var totalBytes: Int64
    public var availableBytes: Int64
    public var isInternal: Bool?
}

public struct InterfaceCounters: Sendable, Equatable {
    public var name: String
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var packetsIn: UInt64
    public var packetsOut: UInt64
    public var isUp: Bool
}

public struct InterfaceRate: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var bytesInPerSecond: Double
    public var bytesOutPerSecond: Double
    public var totalIn: UInt64
    public var totalOut: UInt64
    public var isUp: Bool
}

/// Thin wrappers around Mach / sysctl APIs. No shell commands are used for system-wide metrics.
public enum SystemMetrics {
    public static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return CPUTicks(user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
                        idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
    }

    public static func cpuUsage(from a: CPUTicks, to b: CPUTicks) -> CPUUsage? {
        guard b.total > a.total else { return nil }
        let total = Double(b.total - a.total)
        let user = Double((b.user &- a.user) &+ (b.nice &- a.nice)) / total
        let system = Double(b.system &- a.system) / total
        let idle = Double(b.idle &- a.idle) / total
        return CPUUsage(user: user, system: system, idle: idle)
    }

    public static func memory() -> MemoryStats? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        let cached = (UInt64(stats.external_page_count) + purgeable) * page
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapOK = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        let levelOK = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0
        return MemoryStats(physicalBytes: ProcessInfo.processInfo.physicalMemory,
                           usedBytes: app + wired + compressed, wiredBytes: wired, compressedBytes: compressed,
                           appBytes: app, cachedBytes: cached,
                           swapUsedBytes: swapOK ? swap.xsu_used : nil, swapTotalBytes: swapOK ? swap.xsu_total : nil,
                           pressureLevel: levelOK ? Int(level) : nil)
    }

    public static func volumes() -> [VolumeStats] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsBrowsableKey, .volumeIsReadOnlyKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            // Read-only volumes (mounted disk images, the sealed system snapshot) always look full; skip them.
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false, v.volumeIsReadOnly != true,
                  let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let available = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            return VolumeStats(name: v.volumeName ?? url.lastPathComponent, mountPoint: url.path,
                               totalBytes: Int64(total), availableBytes: available, isInternal: v.volumeIsInternal)
        }
    }

    /// 64-bit interface counters via sysctl NET_RT_IFLIST2 (getifaddrs counters wrap at 4 GB).
    public static func interfaceCounters() -> [InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [] }
        var result: [InterfaceCounters] = []
        var offset = 0
        buffer.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let msgLen = Int(header.ifm_msglen)
                guard msgLen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(h2.ifm_index), &nameBuf) != nil {
                        let name = stringFromCBuffer(nameBuf)
                        let d = h2.ifm_data
                        result.append(InterfaceCounters(name: name, bytesIn: d.ifi_ibytes, bytesOut: d.ifi_obytes,
                                                        packetsIn: d.ifi_ipackets, packetsOut: d.ifi_opackets,
                                                        isUp: (h2.ifm_flags & IFF_UP) != 0))
                    }
                }
                offset += msgLen
            }
        }
        return result
    }

    /// IPv4/IPv6 addresses per interface (getifaddrs), numeric.
    public static func interfaceAddresses() -> [String: [String]] {
        var addrs: [String: [String]] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [:] }
        defer { freeifaddrs(first) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let name = String(cString: p.pointee.ifa_name)
            if let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let len = socklen_t(sa.pointee.sa_family == UInt8(AF_INET) ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
                if getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addrs[name, default: []].append(stringFromCBuffer(host))
                }
            }
            ptr = p.pointee.ifa_next
        }
        // IPv4 first, then global IPv6, then link-local (fe80::).
        return addrs.mapValues { list in
            list.sorted { a, b in
                func rank(_ s: String) -> Int { s.contains(":") ? (s.lowercased().hasPrefix("fe80") ? 2 : 1) : 0 }
                return rank(a) < rank(b)
            }
        }
    }

    public static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    public static func loadAverages() -> [Double]? {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads : nil
    }

    public static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return stringFromCBuffer(buf)
    }
}
