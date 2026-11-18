import SwiftUI

enum SecuritySection: String, CaseIterable, Identifiable {
    case identity = "Identity"
    case digitalFootprint = "Digital Footprint"
    case domains = "Domains"
    case dns = "DNS"
    case web = "Web"
    case network = "Network"
    case system = "System"
    case software = "Software"
    case secrets = "Secrets"
    case vulnerabilities = "Vulnerabilities"
    case threatIntelligence = "Threat Intelligence"
    case findings = "Findings"
    case reports = "Reports"
    
    var id: String { self.rawValue }
    
    var icon: String {
        switch self {
        case .identity: return "person.crop.circle.dashed"
        case .digitalFootprint: return "shoeprints.fill"
        case .domains: return "globe.americas"
        case .dns: return "network"
        case .web: return "safari"
        case .network: return "wifi.router"
        case .system: return "desktopcomputer"
        case .software: return "square.stack.3d.up"
        case .secrets: return "key.fill"
        case .vulnerabilities: return "lock.open.trianglebadge.exclamationmark"
        case .threatIntelligence: return "shield.lefthalf.filled"
        case .findings: return "exclamationmark.shield"
        case .reports: return "doc.text.magnifyingglass"
        }
    }
}

struct SecuritySidebarView: View {
    @Binding var selectedSection: SecuritySection?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SECURITY.INTEL")
                .font(.system(.subheadline, design: .monospaced).bold())
                .foregroundColor(.red)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            
            Divider()
                .background(Color.red.opacity(0.3))
            
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(SecuritySection.allCases) { section in
                        Button(action: {
                            selectedSection = section
                        }) {
                            HStack {
                                Image(systemName: section.icon)
                                    .frame(width: 20)
                                    .foregroundColor(selectedSection == section ? .black : .red.opacity(0.7))
                                Text(section.rawValue.uppercased())
                                    .font(.system(.caption, design: .monospaced).bold())
                                    .foregroundColor(selectedSection == section ? .black : .red.opacity(0.8))
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(selectedSection == section ? Color.red : Color.clear)
                            .cornerRadius(4)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .padding()
        .frame(width: 200, alignment: .topLeading)
        .background(Color.black.opacity(0.85))
        .border(Color.red.opacity(0.3), width: 1)
        .environment(\.colorScheme, .dark)
    }
}
