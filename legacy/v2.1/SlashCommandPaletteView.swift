import SwiftUI
import AppKit

struct SlashCommandPaletteView: View {
    let searchText: String
    let themeColor: Color
    let onSelect: (SlashCommandItem) -> Void
    let onDismiss: () -> Void
    
    @State private var selectedCategory: SlashCommandCategory = .all
    @State private var selectedIndex: Int = 0
    @State private var keyMonitor: Any? = nil
    
    private var filteredCommands: [SlashCommandItem] {
        SlashCommandRegistry.shared.filter(query: searchText, category: selectedCategory)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Dropdown Header with Category Pills and Dismiss Hint
            HStack(spacing: 8) {
                // Category Pills (like Skills / Modes selector)
                HStack(spacing: 4) {
                    ForEach(SlashCommandCategory.allCases) { category in
                        let isSelected = selectedCategory == category
                        let count = SlashCommandRegistry.shared.filter(query: "", category: category).count
                        
                        Button(action: {
                            selectedCategory = category
                            selectedIndex = 0
                        }) {
                            HStack(spacing: 3) {
                                Text(category.rawValue)
                                    .font(.system(size: 10, weight: isSelected ? .bold : .medium, design: .default))
                                Text("\(count)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .opacity(isSelected ? 0.9 : 0.5)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(isSelected ? Color.white.opacity(0.16) : Color.clear)
                            .foregroundColor(isSelected ? .white : Color.white.opacity(0.6))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityLabel("Filter by category \(category.rawValue)")
                    }
                }
                
                Spacer()
                
                // Keyboard helper hints
                HStack(spacing: 6) {
                    Text("↑↓")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                    Text("navigate")
                        .font(.system(size: 9))
                    Text("↵")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                    Text("select")
                        .font(.system(size: 9))
                    Text("esc")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                }
                .foregroundColor(Color.white.opacity(0.4))
                
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.5))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Close dropdown")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(red: 0.13, green: 0.14, blue: 0.17))
            
            Divider()
                .background(Color.white.opacity(0.08))
            
            // Dropdown List Items
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if filteredCommands.isEmpty {
                            HStack {
                                Spacer()
                                Text("No commands found for '\(searchText)'")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color.white.opacity(0.4))
                                    .padding(.vertical, 20)
                                Spacer()
                            }
                        } else {
                            ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, item in
                                let isSelected = selectedIndex == index
                                
                                Button(action: {
                                    onSelect(item)
                                }) {
                                    HStack(alignment: .center, spacing: 10) {
                                        // Simple clean square icon container
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 5)
                                                .fill(Color.white.opacity(0.07))
                                                .frame(width: 24, height: 24)
                                            Image(systemName: item.icon)
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundColor(categoryColor(item.category))
                                        }
                                        
                                        // Title, Command, Description
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(item.command)
                                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                                    .foregroundColor(.white)
                                                
                                                Text(item.title)
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundColor(Color.white.opacity(0.7))
                                                
                                                Spacer()
                                                
                                                if item.requiresArgs {
                                                    Text(item.syntax)
                                                        .font(.system(size: 10, design: .monospaced))
                                                        .foregroundColor(Color.white.opacity(0.35))
                                                }
                                                
                                                Text(item.risk)
                                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1)
                                                    .background(riskColor(item.risk).opacity(0.18))
                                                    .foregroundColor(riskColor(item.risk))
                                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                            }
                                            
                                            Text(item.description)
                                                .font(.system(size: 10.5))
                                                .foregroundColor(Color.white.opacity(0.55))
                                                .lineLimit(1)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
                                    )
                                }
                                .buttonStyle(PlainButtonStyle())
                                .id(index)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(item.command), \(item.title). \(item.description)")
                                .accessibilityHint("Press return to select this command.")
                            }
                        }
                    }
                    .padding(5)
                }
                .frame(maxHeight: 240)
                .onChange(of: selectedIndex) { _, newIndex in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
                .onChange(of: searchText) { _, _ in
                    selectedIndex = 0
                }
            }
        }
        .background(Color(red: 0.11, green: 0.12, blue: 0.14))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: -3)
        .onAppear {
            setupKeyboardMonitor()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
    }
    
    private func setupKeyboardMonitor() {
        removeKeyboardMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 126: // Up arrow
                if selectedIndex > 0 {
                    selectedIndex -= 1
                } else if !filteredCommands.isEmpty {
                    selectedIndex = filteredCommands.count - 1
                }
                return nil
            case 125: // Down arrow
                if selectedIndex + 1 < filteredCommands.count {
                    selectedIndex += 1
                } else {
                    selectedIndex = 0
                }
                return nil
            case 36, 76: // Return / Enter
                if !filteredCommands.isEmpty && selectedIndex >= 0 && selectedIndex < filteredCommands.count {
                    onSelect(filteredCommands[selectedIndex])
                    return nil
                }
                return event
            case 48: // Tab
                if !filteredCommands.isEmpty && selectedIndex >= 0 && selectedIndex < filteredCommands.count {
                    onSelect(filteredCommands[selectedIndex])
                    return nil
                }
                return event
            case 53: // Escape
                onDismiss()
                return nil
            default:
                return event
            }
        }
    }
    
    private func removeKeyboardMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
    
    private func categoryColor(_ cat: SlashCommandCategory) -> Color {
        switch cat {
        case .all: return Color(white: 0.7)
        case .audits: return Color(red: 0.95, green: 0.45, blue: 0.45)
        case .actions: return Color(red: 0.95, green: 0.75, blue: 0.35)
        case .system: return Color(red: 0.45, green: 0.85, blue: 0.55)
        case .ai: return Color(red: 0.45, green: 0.75, blue: 0.95)
        }
    }
    
    private func riskColor(_ risk: String) -> Color {
        switch risk.uppercased() {
        case "AUDIT": return Color(red: 0.95, green: 0.45, blue: 0.45)
        case "REMEDIATE": return Color(red: 0.95, green: 0.75, blue: 0.35)
        case "SAFE": return Color(red: 0.45, green: 0.85, blue: 0.55)
        case "INFO": return Color(red: 0.45, green: 0.75, blue: 0.95)
        default: return Color(white: 0.6)
        }
    }
}
