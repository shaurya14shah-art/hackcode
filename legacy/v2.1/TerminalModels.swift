import Foundation
import SwiftUI

enum MessageType {
    case userInput
    case aiResponse
    case systemStatus
    case commandOutput
    case error
    case blocked
}

enum TerminalState: String {
    case idle = "IDLE"
    case thinking = "THINKING"
    case commandReady = "COMMAND_READY"
    case confirmationRequired = "CONFIRM"
    case executing = "EXECUTING"
    case complete = "COMPLETE"
    case error = "ERROR"
    case blocked = "BLOCKED"
}

struct TerminalMessage: Identifiable {
    let id = UUID()
    let text: String
    let type: MessageType
    var command: String?
    var risk: String?
    var requiresConfirmation: Bool = false
    var executionResult: String?
    
    var prefixText: String {
        switch type {
        case .userInput: return "root@mac ~ %"
        case .aiResponse: return "SYS.AI >"
        case .systemStatus: return "SYS >"
        case .commandOutput: return "OUT >"
        case .error: return "ERR >"
        case .blocked: return "BLOCKED >"
        }
    }
    
    var color: Color {
        switch type {
        case .userInput: return .white
        case .aiResponse: return .green
        case .systemStatus: return Color(red: 0.4, green: 0.8, blue: 0.4)
        case .commandOutput: return Color(red: 0.7, green: 0.9, blue: 0.7)
        case .error: return .red
        case .blocked: return .yellow
        }
    }
    
    var prefixColor: Color {
        switch type {
        case .userInput: return .white
        case .aiResponse: return .green
        case .systemStatus: return .green.opacity(0.6)
        case .commandOutput: return .green.opacity(0.5)
        case .error: return .red
        case .blocked: return .yellow
        }
    }
}
