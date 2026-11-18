import Foundation

print("Starting native CLI test...")

let llm = LLMService()

Task {
    print("Testing CommandExecutor...")
    let result = CommandExecutor.execute("uptime")
    print("Command result: \(result)")
    
    print("Testing LLMService API latency...")
    let start = Date()
    do {
        let aiResult = try await llm.analyzeProblem("Check what process is taking up memory.")
        let latency = Date().timeIntervalSince(start)
        print("LLM Response received in \(String(format: "%.2f", latency))s:")
        print("Risk: \(aiResult.risk)")
        print("Explanation: \(aiResult.explanation)")
    } catch {
        print("LLM Error: \(error)")
    }
    
    exit(0)
}

RunLoop.main.run()
