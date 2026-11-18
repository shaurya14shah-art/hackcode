import Foundation

struct ProcessInfoModel: Identifiable, Hashable {
    let id = UUID()
    let pid: String
    let name: String
    let cpuUsage: Double
    let memoryUsage: Double // in MB
    var explanation: String?
    
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ProcessInfoModel, rhs: ProcessInfoModel) -> Bool { lhs.id == rhs.id }
}

class ProcessManager: ObservableObject {
    @Published var processes: [ProcessInfoModel] = []
    @Published var isRefreshing = false
    
    func refreshProcesses() {
        DispatchQueue.main.async {
            self.isRefreshing = true
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CommandExecutor.execute(executable: "/bin/sh", arguments: ["-c", "ps -arcxw -o pid,%cpu,rss,comm | head -n 21 | tail -n +2"])
            let output = result.displayOutput
            
            let parsedProcesses = self.parsePSOutput(output)
            
            DispatchQueue.main.async {
                self.processes = parsedProcesses
                self.isRefreshing = false
            }
        }
    }
    
    internal func parsePSOutput(_ output: String) -> [ProcessInfoModel] {
        let lines = output.split(separator: "\n")
        var result: [ProcessInfoModel] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4 else { continue }
            
            let pid = String(parts[0])
            let cpuUsage = Double(parts[1]) ?? 0.0
            let memoryUsageKB = Double(parts[2]) ?? 0.0
            let name = String(parts[3])
            
            let memoryUsageMB = memoryUsageKB / 1024.0
            
            let model = ProcessInfoModel(
                pid: pid,
                name: name,
                cpuUsage: cpuUsage,
                memoryUsage: memoryUsageMB
            )
            
            result.append(model)
            
            if result.count >= 20 {
                break
            }
        }
        
        return result
    }
    
    @MainActor
    func updateExplanation(for pid: String, explanation: String) {
        if let index = processes.firstIndex(where: { $0.pid == pid }) {
            processes[index].explanation = explanation
        }
    }
}
