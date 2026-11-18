import Foundation
import CoreWLAN

/// Encryption of the current Wi-Fi association, classified for a security reading.
public enum WiFiSecurity: String, Sendable, Equatable {
    case open = "Open (no encryption)", wep = "WEP", wpa = "WPA", wpaMixed = "WPA/WPA2 mixed"
    case wpa2 = "WPA2", wpa2Enterprise = "WPA2 Enterprise", wpa3 = "WPA3", wpa3Enterprise = "WPA3 Enterprise"
    case wpa3Transition = "WPA2/WPA3 transition", owe = "OWE (enhanced open)", unknown = "Unknown"

    public enum Strength: String, Sendable, Comparable {
        case weak = "WEAK", fair = "FAIR", good = "GOOD", strong = "STRONG", unknown = "UNKNOWN"
        static let order: [Strength] = [.unknown, .weak, .fair, .good, .strong]
        public static func < (a: Strength, b: Strength) -> Bool { order.firstIndex(of: a)! < order.firstIndex(of: b)! }
    }

    /// Maps `CWSecurity` raw values (stable since macOS 10.7; WPA3/OWE added in 10.15/11).
    public init(cwRawValue raw: Int) {
        switch raw {
        case 0: self = .open
        case 1, 6: self = .wep
        case 2, 7: self = .wpa
        case 3, 8: self = .wpaMixed
        case 4, 5: self = .wpa2
        case 9, 10: self = .wpa2Enterprise
        case 11: self = .wpa3
        case 12: self = .wpa3Enterprise
        case 13: self = .wpa3Transition
        case 14, 15: self = .owe
        default: self = .unknown
        }
    }

    public var strength: Strength {
        switch self {
        case .open, .wep, .wpa: return .weak
        case .wpaMixed, .owe: return .fair
        case .wpa2, .wpa2Enterprise, .wpa3Transition: return .good
        case .wpa3, .wpa3Enterprise: return .strong
        case .unknown: return .unknown
        }
    }

    public var advice: String {
        switch self {
        case .open: return "Traffic on this network is not encrypted; anyone nearby can read unencrypted traffic. Prefer a WPA2/WPA3 network or use a VPN."
        case .wep: return "WEP can be cracked in minutes. Switch the router to WPA2/WPA3 or avoid this network."
        case .wpa: return "WPA (TKIP) is deprecated and weak. Switch the router to WPA2 (AES) or WPA3."
        case .wpaMixed: return "Mixed WPA/WPA2 mode still allows weak TKIP clients. Prefer WPA2 (AES) only, or WPA3."
        case .owe: return "Encrypted but unauthenticated (anyone can join). Fine for public hotspots; use a VPN for sensitive work."
        case .wpa2, .wpa2Enterprise: return "WPA2 is acceptable. WPA3 adds protection against offline password guessing."
        case .wpa3Transition: return "WPA3 with WPA2 fallback for older devices."
        case .wpa3, .wpa3Enterprise: return "WPA3 is current best practice for Wi-Fi encryption."
        case .unknown: return "macOS did not report the security type."
        }
    }
}

public enum SignalQuality: String, Sendable {
    case excellent = "EXCELLENT", good = "GOOD", fair = "FAIR", poor = "POOR"

    /// Common RSSI bands (dBm).
    public init(rssi: Int) {
        switch rssi {
        case (-55)...: self = .excellent
        case (-67)...: self = .good
        case (-75)...: self = .fair
        default: self = .poor
        }
    }

    public var bars: Int {
        switch self { case .excellent: return 4; case .good: return 3; case .fair: return 2; case .poor: return 1 }
    }
}

public struct WiFiStatus: Sendable, Equatable {
    public var interface: String
    public var poweredOn: Bool
    /// False when powered on but not joined to a network.
    public var associated: Bool
    public var rssi: Int
    public var noise: Int
    public var transmitRateMbps: Double
    public var security: WiFiSecurity
    public var phyMode: String
    public var channel: Int?
    public var band: String?
    public var channelWidthMHz: Int?

    public var snr: Int { rssi - noise }
    public var quality: SignalQuality { SignalQuality(rssi: rssi) }

    public init(interface: String, poweredOn: Bool, associated: Bool, rssi: Int, noise: Int, transmitRateMbps: Double,
                security: WiFiSecurity, phyMode: String, channel: Int?, band: String?, channelWidthMHz: Int?) {
        self.interface = interface
        self.poweredOn = poweredOn
        self.associated = associated
        self.rssi = rssi
        self.noise = noise
        self.transmitRateMbps = transmitRateMbps
        self.security = security
        self.phyMode = phyMode
        self.channel = channel
        self.band = band
        self.channelWidthMHz = channelWidthMHz
    }

    /// Evidence text for the audit check (no network name or BSSID — those need Location permission and are not used).
    public var evidenceText: String {
        guard poweredOn else { return "poweredOn = no\nassociated = no" }
        guard associated else { return "poweredOn = yes\nassociated = no" }
        let ch = channel.map { "\($0)" + (band.map { " (\($0)" } ?? "") + (channelWidthMHz.map { ", \($0) MHz)" } ?? (band == nil ? "" : ")")) } ?? "unknown"
        return """
        poweredOn = yes
        associated = yes
        security = \(security.rawValue)
        strength = \(security.strength.rawValue)
        rssi = \(rssi) dBm (\(quality.rawValue))
        noise = \(noise) dBm · snr = \(snr) dB
        channel = \(ch)
        phy = \(phyMode)
        txRate = \(Int(transmitRateMbps)) Mbps
        """
    }
}

public enum WiFiMetrics {
    /// Reads the default Wi-Fi interface (CoreWLAN; no network name, so no Location permission is needed). nil without Wi-Fi hardware.
    public static func current() -> WiFiStatus? {
        guard let i = CWWiFiClient.shared().interface() else { return nil }
        let on = i.powerOn()
        let rssi = i.rssiValue()
        let ch = i.wlanChannel()
        let band: String? = ch.flatMap {
            switch $0.channelBand { case .band2GHz: return "2.4 GHz"; case .band5GHz: return "5 GHz"; case .band6GHz: return "6 GHz"; default: return nil }
        }
        let width: Int? = ch.flatMap {
            switch $0.channelWidth { case .width20MHz: return 20; case .width40MHz: return 40; case .width80MHz: return 80; case .width160MHz: return 160; default: return nil }
        }
        return WiFiStatus(interface: i.interfaceName ?? "en0", poweredOn: on, associated: on && rssi != 0,
                          rssi: rssi, noise: i.noiseMeasurement(), transmitRateMbps: i.transmitRate(),
                          security: WiFiSecurity(cwRawValue: i.security().rawValue), phyMode: phyName(i.activePHYMode().rawValue),
                          channel: ch?.channelNumber, band: band, channelWidthMHz: width)
    }

    static func phyName(_ raw: Int) -> String {
        switch raw {
        case 1: return "802.11a"
        case 2: return "802.11b"
        case 3: return "802.11g"
        case 4: return "802.11n (Wi-Fi 4)"
        case 5: return "802.11ac (Wi-Fi 5)"
        case 6: return "802.11ax (Wi-Fi 6/6E)"
        case 7: return "802.11be (Wi-Fi 7)"
        default: return "unknown"
        }
    }
}
