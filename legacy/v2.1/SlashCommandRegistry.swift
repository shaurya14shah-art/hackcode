import Foundation

// MARK: - Slash Command Categories
enum SlashCommandCategory: String, CaseIterable, Identifiable {
    case all = "ALL"
    case audits = "AUDITS"
    case actions = "ACTIONS"
    case system = "SYSTEM"
    case ai = "AI ADVISOR"
    
    var id: String { rawValue }
    
    var badgeColor: String {
        switch self {
        case .all: return "gray"
        case .audits: return "red"
        case .actions: return "yellow"
        case .system: return "green"
        case .ai: return "cyan"
        }
    }
}

// MARK: - Slash Command Item
struct SlashCommandItem: Identifiable, Hashable {
    let id: String
    let command: String
    let title: String
    let category: SlashCommandCategory
    let description: String
    let syntax: String
    let icon: String
    let risk: String
    let requiresArgs: Bool
    
    init(
        command: String,
        title: String,
        category: SlashCommandCategory,
        description: String,
        syntax: String? = nil,
        icon: String,
        risk: String = "SAFE",
        requiresArgs: Bool = false
    ) {
        self.id = command
        self.command = command
        self.title = title
        self.category = category
        self.description = description
        self.syntax = syntax ?? command
        self.icon = icon
        self.risk = risk
        self.requiresArgs = requiresArgs
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(command)
    }
    
    static func == (lhs: SlashCommandItem, rhs: SlashCommandItem) -> Bool {
        lhs.command == rhs.command
    }
}

// MARK: - Slash Command Registry
class SlashCommandRegistry {
    static let shared = SlashCommandRegistry()
    
    let allCommands: [SlashCommandItem] = [
        // --- AUDITS ---
        SlashCommandItem(
            command: "/audit",
            title: "Full Security Posture Audit",
            category: .audits,
            description: "Runs full automated assessment across all system hardening, network, and security modules.",
            icon: "shield.checkered",
            risk: "AUDIT"
        ),
        SlashCommandItem(
            command: "/audit-firewall",
            title: "Audit Application Firewall",
            category: .audits,
            description: "Audits socketfilterfw global state, stealth mode, and inbound block policies.",
            icon: "flame.fill",
            risk: "AUDIT"
        ),
        SlashCommandItem(
            command: "/audit-sip",
            title: "Audit System Integrity Protection",
            category: .audits,
            description: "Checks csrutil status to verify that macOS rootless system protection is actively enforced.",
            icon: "lock.shield.fill",
            risk: "AUDIT"
        ),
        SlashCommandItem(
            command: "/audit-gatekeeper",
            title: "Audit Gatekeeper & Code Signatures",
            category: .audits,
            description: "Audits spctl status to ensure only cryptographically verified applications can execute.",
            icon: "checkmark.seal.fill",
            risk: "AUDIT"
        ),
        SlashCommandItem(
            command: "/audit-filevault",
            title: "Audit FileVault Disk Encryption",
            category: .audits,
            description: "Checks fdesetup status to ensure the startup volume is encrypted with XTS-AES-128.",
            icon: "lock.laptopcomputer",
            risk: "AUDIT"
        ),
        SlashCommandItem(
            command: "/audit-ssh",
            title: "Audit SSH Remote Login",
            category: .audits,
            description: "Checks systemsetup to detect whether SSH remote login daemon is active.",
            icon: "terminal.fill",
            risk: "AUDIT"
        ),
        SlashCommandItem(
            command: "/audit-sharing",
            title: "Audit Remote Sharing Services",
            category: .audits,
            description: "Audits Screen Sharing, File Sharing, Remote Apple Events, and AirDrop visibility.",
            icon: "shareplay",
            risk: "AUDIT"
        ),
        SlashCommandItem(
            command: "/audit-autoupdate",
            title: "Audit Automatic Software Updates",
            category: .audits,
            description: "Checks softwareupdate schedule for automatic macOS security patch downloads.",
            icon: "arrow.triangle.2.circlepath.circle.fill",
            risk: "AUDIT"
        ),
        SlashCommandItem(
            command: "/audit-screenlock",
            title: "Audit Screen Saver & Lock Delay",
            category: .audits,
            description: "Audits screensaver idle timers and password requirement immediately on wake.",
            icon: "lock.fill",
            risk: "AUDIT"
        ),
        SlashCommandItem(
            command: "/audit-secrets",
            title: "Scan for Exposed Secrets & Keys",
            category: .audits,
            description: "Scans local directories and repositories for leaked API tokens, private keys, and passwords.",
            icon: "key.fill",
            risk: "AUDIT"
        ),
        SlashCommandItem(
            command: "/audit-ports",
            title: "Scan Local TCP Listening Ports",
            category: .audits,
            description: "Probes local TCP listening ports (21-9090) to identify exposed network services.",
            icon: "network",
            risk: "AUDIT"
        ),
        SlashCommandItem(
            command: "/audit-dns",
            title: "Audit DNS Resolution Security",
            category: .audits,
            description: "Audits DNS resolver settings, MX records, and TXT security configuration.",
            icon: "globe",
            risk: "AUDIT"
        ),
        SlashCommandItem(
            command: "/audit-network",
            title: "Subnet Discovery & Topology",
            category: .audits,
            description: "Executes ARP table inspection and ping sweep on local subnet to map devices and gateway.",
            syntax: "/audit-network",
            icon: "point.3.connected.trianglepath.dotted",
            risk: "AUDIT"
        ),
        
        // --- ACTIONS ---
        SlashCommandItem(
            command: "/status",
            title: "Audit Status & Posture Score",
            category: .actions,
            description: "Displays live audit engine state, overall posture score (0-100), and findings count.",
            icon: "speedometer",
            risk: "INFO"
        ),
        SlashCommandItem(
            command: "/report",
            title: "Generate Compliance Audit Report",
            category: .actions,
            description: "Compiles formal markdown security assessment report with prioritized remediation roadmap.",
            icon: "doc.text.fill",
            risk: "INFO"
        ),
        SlashCommandItem(
            command: "/findings",
            title: "List Discovered Vulnerabilities",
            category: .actions,
            description: "Displays all currently identified security findings grouped by severity level.",
            icon: "exclamationmark.triangle.fill",
            risk: "INFO"
        ),
        SlashCommandItem(
            command: "/remediate",
            title: "Show Remediation Recommendations",
            category: .actions,
            description: "Lists step-by-step remediation advice and commands for all active findings.",
            icon: "wrench.and.screwdriver.fill",
            risk: "INFO"
        ),
        SlashCommandItem(
            command: "/remediate-finding",
            title: "Execute Remediation Fix",
            category: .actions,
            description: "Applies automated hardening remediation fix for finding index number <N>.",
            syntax: "/remediate <number>",
            icon: "bandage.fill",
            risk: "REMEDIATE",
            requiresArgs: true
        ),
        SlashCommandItem(
            command: "/cancel",
            title: "Emergency Kill Switch",
            category: .actions,
            description: "Instantly aborts any actively running security audit or network scan.",
            icon: "xmark.octagon.fill",
            risk: "SAFE"
        ),
        
        // --- SYSTEM ---
        SlashCommandItem(
            command: "/whoami",
            title: "Current User & Privileges",
            category: .system,
            description: "Displays current user account name, UID, and administrative group memberships.",
            icon: "person.crop.circle.fill",
            risk: "SAFE"
        ),
        SlashCommandItem(
            command: "/uptime",
            title: "System Uptime & Load Averages",
            category: .system,
            description: "Displays system running time and 1, 5, 15-minute CPU load averages.",
            icon: "clock.fill",
            risk: "SAFE"
        ),
        SlashCommandItem(
            command: "/info",
            title: "macOS System Specifications",
            category: .system,
            description: "Displays macOS product version, Darwin kernel release, and hardware architecture.",
            icon: "info.circle.fill",
            risk: "SAFE"
        ),
        SlashCommandItem(
            command: "/processes",
            title: "Active Process Inspector",
            category: .system,
            description: "Lists running system processes sorted by CPU and memory consumption.",
            icon: "cpu",
            risk: "SAFE"
        ),
        SlashCommandItem(
            command: "/clear",
            title: "Clear Terminal Screen",
            category: .system,
            description: "Resets the terminal log output buffer and clears the screen.",
            icon: "trash.fill",
            risk: "SAFE"
        ),
        SlashCommandItem(
            command: "/help",
            title: "Command Reference Manual",
            category: .system,
            description: "Displays complete reference documentation for all slash commands and audits.",
            icon: "questionmark.circle.fill",
            risk: "INFO"
        ),
        
        // --- AI ADVISOR ---
        SlashCommandItem(
            command: "/set-key",
            title: "Configure NVIDIA API Key",
            category: .ai,
            description: "Stores NVIDIA API key securely in the macOS Keychain under HackCode service.",
            syntax: "/set-key <YOUR_KEY>",
            icon: "key.horizontal.fill",
            risk: "SAFE",
            requiresArgs: true
        ),
        SlashCommandItem(
            command: "/advisor",
            title: "Consult AI Security Advisor",
            category: .ai,
            description: "Queries LLM security analyst with live findings context for hardening advice.",
            syntax: "/advisor <question>",
            icon: "sparkles",
            risk: "SAFE",
            requiresArgs: true
        )
    ]
    
    func filter(query: String, category: SlashCommandCategory = .all) -> [SlashCommandItem] {
        var cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleanQuery.hasPrefix("/") {
            cleanQuery = String(cleanQuery.dropFirst())
        }
        
        return allCommands.filter { item in
            // Category filter
            if category != .all && item.category != category {
                return false
            }
            
            // Text filter
            if cleanQuery.isEmpty {
                return true
            }
            
            let cmdClean = item.command.hasPrefix("/") ? String(item.command.dropFirst()) : item.command
            return cmdClean.localizedCaseInsensitiveContains(cleanQuery)
                || item.title.localizedCaseInsensitiveContains(cleanQuery)
                || item.description.localizedCaseInsensitiveContains(cleanQuery)
                || item.category.rawValue.localizedCaseInsensitiveContains(cleanQuery)
        }
    }
}
