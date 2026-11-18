import Foundation
import IOKit
import IOKit.ps

public struct BatteryStatus: Sendable, Equatable {
    public var percent: Int
    public var isCharging: Bool
    public var onAC: Bool
    /// Minutes, when macOS has an estimate.
    public var minutesRemaining: Int?
    public var cycleCount: Int?
    /// Full-charge capacity as a fraction of design capacity, when the battery reports both.
    public var health: Double?
    public var condition: String?
}

public enum PowerMetrics {
    /// nil on Macs without a battery.
    public static func battery() -> BatteryStatus? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let tte = d[kIOPSTimeToEmptyKey] as? Int ?? -1
            let ttf = d[kIOPSTimeToFullChargeKey] as? Int ?? -1
            let minutes = charging ? (ttf > 0 ? ttf : nil) : (tte > 0 ? tte : nil)
            var status = BatteryStatus(percent: Int((Double(current) / Double(max) * 100).rounded()), isCharging: charging, onAC: onAC,
                                       minutesRemaining: minutes, cycleCount: nil, health: nil,
                                       condition: d["BatteryHealth"] as? String)
            let registry = smartBatteryProperties()
            status.cycleCount = registry["CycleCount"] as? Int
            if let design = registry["DesignCapacity"] as? Int, design > 0,
               let full = (registry["AppleRawMaxCapacity"] as? Int) ?? (registry["NominalChargeCapacity"] as? Int) {
                status.health = Double(full) / Double(design)
            }
            return status
        }
        return nil
    }

    private static func smartBatteryProperties() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return [:] }
        return dict
    }

    public static var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "NOMINAL"
        case .fair: return "FAIR"
        case .serious: return "SERIOUS"
        case .critical: return "CRITICAL"
        @unknown default: return "UNKNOWN"
        }
    }
}
