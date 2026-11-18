import SwiftUI

struct SecurityDashboardView: View {
    @ObservedObject var engine: SecurityEngine
    @ObservedObject var llmService: LLMService
    var selectedSection: SecuritySection?
    
    private var exposedServicesCount: String {
        guard let findings = engine.session?.findings else { return "--" }
        return "\(findings.filter { $0.category.localizedCaseInsensitiveContains("NETWORK") || $0.title.localizedCaseInsensitiveContains("SSH") || $0.title.localizedCaseInsensitiveContains("sharing") }.count)"
    }
    
    private var outdatedSoftwareCount: String {
        guard let findings = engine.session?.findings else { return "--" }
        return "\(findings.filter { $0.category.localizedCaseInsensitiveContains("SOFTWARE") }.count)"
    }
    
    private var secretsDetectedCount: String {
        guard let findings = engine.session?.findings else { return "--" }
        return "\(findings.filter { $0.category.localizedCaseInsensitiveContains("SECRETS") }.count)"
    }
    
    private var configurationIssuesCount: String {
        guard let findings = engine.session?.findings else { return "--" }
        return "\(findings.filter { $0.category.localizedCaseInsensitiveContains("CONFIGURATION") || $0.category.localizedCaseInsensitiveContains("HARDENING") }.count)"
    }

    private var criticalCount: String {
        guard let findings = engine.session?.findings else { return "--" }
        return "\(findings.filter { $0.severity == .critical }.count)"
    }

    private var highCount: String {
        guard let findings = engine.session?.findings else { return "--" }
        return "\(findings.filter { $0.severity == .high }.count)"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    Text(selectedSection?.rawValue.uppercased() ?? "SECURITY OVERVIEW")
                        .font(.system(.title2, design: .monospaced).bold())
                        .foregroundColor(.red)
                        .padding(.bottom, 8)
                    
                    // Dashboard Grid
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        MetricBox(title: "SECURITY POSTURE", value: engine.session?.overallScore != nil ? "\(engine.session!.overallScore)/100" : "UNKNOWN", isCritical: false)
                        MetricBox(title: "ASSETS", value: "\(engine.graph.assets.count)", isCritical: false)
                        MetricBox(title: "FINDINGS", value: "\(engine.session?.findings.count ?? 0)", isCritical: (engine.session?.findings.count ?? 0) > 0)
                        MetricBox(title: "CRITICAL FINDINGS", value: criticalCount, isCritical: (Int(criticalCount) ?? 0) > 0)
                        MetricBox(title: "HIGH FINDINGS", value: highCount, isCritical: (Int(highCount) ?? 0) > 0)
                        MetricBox(title: "EXPOSED SERVICES", value: exposedServicesCount, isCritical: (Int(exposedServicesCount) ?? 0) > 0)
                        MetricBox(title: "OUTDATED SOFTWARE", value: outdatedSoftwareCount, isCritical: (Int(outdatedSoftwareCount) ?? 0) > 0)
                        MetricBox(title: "SECRETS DETECTED", value: secretsDetectedCount, isCritical: false)
                        MetricBox(title: "CONFIGURATION ISSUES", value: configurationIssuesCount, isCritical: (Int(configurationIssuesCount) ?? 0) > 0)
                    }
                    
                    Divider().background(Color.red.opacity(0.3)).padding(.vertical, 8)
                    
                    if selectedSection == .findings {
                        findingsListView
                    } else if selectedSection == .system {
                        Text("SYSTEM ASSETS")
                            .font(.system(.headline, design: .monospaced))
                            .foregroundColor(.red)
                        
                        ForEach(Array(engine.graph.assets.values), id: \.id) { asset in
                            HStack {
                                Text(asset.name)
                                Spacer()
                                Text(asset.type.rawValue)
                            }
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .background(Color.black.opacity(0.2))
                            .border(Color.red.opacity(0.2), width: 1)
                            .foregroundColor(.primary)
                        }
                    } else {
                        Text("NO ACTIVE DATA STREAM FOR THIS MODULE")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.red.opacity(0.5))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .background(Color.black.opacity(0.1))
                            .border(Color.red.opacity(0.2), width: 1)
                    }
                }
                .padding(20)
            }
            .background(Color.black.opacity(0.85))
            .border(Color.red.opacity(0.2), width: 1)
            
            SecurityTerminalView(llmService: llmService, engine: engine)
                .frame(minHeight: 150, maxHeight: 300)
        }
        .environment(\.colorScheme, .dark)
    }
    
    private var findingsListView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LATEST FINDINGS")
                .font(.system(.headline, design: .monospaced))
                .foregroundColor(.red)
            
            if let findings = engine.session?.findings, !findings.isEmpty {
                ForEach(findings) { finding in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("[\(finding.severity.rawValue)]")
                                .foregroundColor(severityColor(finding.severity))
                            Text(finding.title)
                                .foregroundColor(.white)
                        }
                        .font(.system(.caption, design: .monospaced).bold())
                        Text(finding.category)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.2))
                    .border(severityColor(finding.severity).opacity(0.5), width: 1)
                }
            } else {
                Text("NO FINDINGS RECORDED")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.green)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .border(Color.green.opacity(0.3), width: 1)
            }
        }
    }
    
    private func severityColor(_ severity: SecuritySeverity) -> Color {
        switch severity {
        case .info: return .blue
        case .low: return .yellow
        case .medium: return .orange
        case .high: return .red
        case .critical: return Color(red: 1.0, green: 0.2, blue: 0.2)
        }
    }
}

struct MetricBox: View {
    let title: String
    let value: String
    let isCritical: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(isCritical ? .red.opacity(0.7) : .white.opacity(0.5))
            
            Text(value)
                .font(.system(.title, design: .monospaced).bold())
                .foregroundColor(isCritical ? .red : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.2))
        .border(isCritical ? Color.red.opacity(0.5) : Color.white.opacity(0.2), width: 1)
    }
}
