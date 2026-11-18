import Foundation
import Combine

class LLMService: ObservableObject {
    @Published var isProcessing = false
    
    private let invokeUrl = URL(string: "https://integrate.api.nvidia.com/v1/chat/completions")!
    private let model = "meta/llama-3.2-11b-vision-instruct"
    
    private var conversationHistory: [[String: String]] = []
    
    struct AIResponse {
        var explanation: String
        var command: String?
        var risk: String
        var requiresConfirmation: Bool
    }
    
    func clearHistory() {
        conversationHistory.removeAll()
    }
    
    /// Sanitizes text before including in LLM prompts to prevent excessive length and control characters.
    private func sanitizeForPrompt(_ text: String, maxLength: Int = 4000) -> String {
        var sanitized = text
        // Remove control characters except newline and tab
        sanitized = sanitized.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
        }.map(String.init).joined()
        // Truncate if too long
        if sanitized.count > maxLength {
            sanitized = String(sanitized.prefix(maxLength)) + "\n[TRUNCATED]"
        }
        return sanitized
    }
    
    private func getAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "HackCode_NVIDIA_API_KEY",
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: AnyObject?
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        if status == errSecSuccess {
            if let data = dataTypeRef as? Data,
               let key = String(data: data, encoding: .utf8) {
                return key
            }
        }
        return nil
    }

    func setAPIKey(_ key: String) -> Bool {
        var cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanKey.lowercased().hasPrefix("bearer ") {
            cleanKey = String(cleanKey.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let keyData = cleanKey.data(using: .utf8) else { return false }
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "HackCode_NVIDIA_API_KEY"
        ]
        SecItemDelete(deleteQuery as CFDictionary) // Delete any existing key first
        
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "HackCode_NVIDIA_API_KEY",
            kSecValueData as String: keyData
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    func analyzeProblem(_ prompt: String) async throws -> AIResponse {
        await MainActor.run { isProcessing = true }
        defer { Task { @MainActor in isProcessing = false } }
        
        let systemPrompt = """
        You are HackCode SYS.ADMIN, an advanced macOS system intelligence layer.
        The user describes a system problem or asks a diagnostic question.
        You determine the appropriate safe macOS terminal command.
        NOTE: On modern macOS (Apple Silicon), commands like `system_profiler SPThermalDataType` or `powermetrics` without sudo often return NO output. Prefer commands like `top -l 1`, `ps aux`, `uptime`, `sw_vers`, `sysctl -a`, or `echo "Data unavailable"` if you know it requires sudo or won't work.
        Respond ONLY with a JSON object. No markdown, no backticks, no explanation outside JSON.
        Format: {"explanation": "Clear technical explanation.", "command": "exact command string", "risk": "LOW|MODERATE|HIGH", "requires_confirmation": false}
        If no command is needed, omit the command field.
        Use calibrated language. Do not guarantee safety of unknown operations.
        """
        
        conversationHistory.append(["role": "user", "content": prompt])
        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }
        
        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        messages.append(contentsOf: conversationHistory)
        
        let payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 1024,
            "temperature": 0.6
        ]
        
        guard let apiKey = getAPIKey() else {
            return AIResponse(explanation: "API Key not found. Please set your NVIDIA API Key securely in the Keychain under 'HackCode_NVIDIA_API_KEY'.", command: nil, risk: "MODERATE", requiresConfirmation: false)
        }
        let data = try await performRequest(payload: payload, apiKey: apiKey)
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let contentString = (message["content"] as? String) ?? (message["reasoning_content"] as? String) ?? "No content returned."
        
        conversationHistory.append(["role": "assistant", "content": contentString])
        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }
        
        var jsonString = contentString
        if let match = contentString.range(of: "(?s)\\{.*\\}", options: [.regularExpression]) {
            jsonString = String(contentString[match])
        }
        
        guard let innerData = jsonString.data(using: .utf8),
              let innerJson = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any],
              let explanation = innerJson["explanation"] as? String else {
            return AIResponse(explanation: contentString, command: nil, risk: "MODERATE", requiresConfirmation: false)
        }
        
        let command = innerJson["command"] as? String
        let cleanCommand = command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : command
        let risk = innerJson["risk"] as? String ?? "MODERATE"
        let requiresConfirmation = innerJson["requires_confirmation"] as? Bool ?? false
        
        return AIResponse(explanation: explanation, command: cleanCommand, risk: risk, requiresConfirmation: requiresConfirmation)
    }
    
    func explainProcess(_ processName: String) async throws -> String {
        let sanitizedName = processName.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).inverted).joined()
        let systemPrompt = """
        You are a macOS systems expert. Explain the given macOS process.
        Cover: what it does, which subsystem it belongs to, typical resource usage, whether its behavior is normal.
        Use calibrated language: known, probable, uncertain, suspicious.
        Do NOT label unknown processes as definitively safe.
        Keep the response concise (2-3 sentences).
        """
        
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Explain process: \(sanitizedName)"]
            ],
            "max_tokens": 150,
            "temperature": 0.2
        ]
        
        guard let apiKey = getAPIKey() else {
            return "API Key not found."
        }
        let data = try await performRequest(payload: payload, apiKey: apiKey, timeout: 30.0)
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let contentString = (message["content"] as? String) ?? (message["reasoning_content"] as? String) ?? "No content returned."
        
        var finalString = contentString
        if let match = contentString.range(of: "(?s)<thought>.*?</thought>\\s*", options: [.regularExpression]) {
            finalString = contentString.replacingCharacters(in: match, with: "")
        } else if let match = contentString.range(of: "(?s)<think>.*?</think>\\s*", options: [.regularExpression]) {
            finalString = contentString.replacingCharacters(in: match, with: "")
        }
        
        return finalString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func analyzeSecurityEvidence(checkName: String, checkCategory: String, evidence: String) async throws -> SecurityFinding {
        let systemPrompt = """
        You are a defensive macOS security auditor. You are analyzing local system configuration.
        Do not invent vulnerabilities. Base your finding ONLY on the provided evidence.
        Respond ONLY with a JSON object. No markdown, no backticks, no explanation outside JSON.
        Format:
        {
          "title": "Short title",
          "severity": "INFO|LOW|MEDIUM|HIGH|CRITICAL",
          "explanation": "What was observed and why it matters.",
          "impact": "Potential security impact.",
          "remediation": "Safe recommendation for fixing this issue, or 'N/A'.",
          "verification": "How to verify the fix.",
          "confidence": "HIGH|MEDIUM|LOW"
        }
        """
        
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Check: \(sanitizeForPrompt(checkName, maxLength: 200))\nCategory: \(sanitizeForPrompt(checkCategory, maxLength: 200))\nEvidence:\n\(sanitizeForPrompt(evidence))"]
            ],
            "max_tokens": 1024,
            "temperature": 0.2
        ]
        
        guard let apiKey = getAPIKey() else {
            return SecurityFinding(title: checkName, category: checkCategory, severity: .info, evidence: [evidence], explanation: "API Key missing.", impact: "Unknown", remediation: "Add API Key", verification: "Run again", confidence: "LOW")
        }
        
        let data = try await performRequest(payload: payload, apiKey: apiKey, timeout: 60.0)
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let contentString = (message["content"] as? String) ?? (message["reasoning_content"] as? String) ?? "{}"
        
        var jsonString = contentString
        if let match = contentString.range(of: "(?s)\\{.*\\}", options: [.regularExpression]) {
            jsonString = String(contentString[match])
        }
        
        guard let innerData = jsonString.data(using: .utf8),
              let innerJson = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any] else {
            return SecurityFinding(title: checkName, category: checkCategory, severity: .info, evidence: [evidence], explanation: "Failed to parse AI response", impact: "Unknown", remediation: "N/A", verification: "N/A", confidence: "LOW")
        }
        
        let title = innerJson["title"] as? String ?? checkName
        let sevString = innerJson["severity"] as? String ?? "INFO"
        let severity = SecuritySeverity(rawValue: sevString) ?? .info
        let explanation = innerJson["explanation"] as? String ?? "No explanation provided."
        let impact = innerJson["impact"] as? String ?? "Unknown impact."
        let remediation = innerJson["remediation"] as? String ?? "No remediation provided."
        let verification = innerJson["verification"] as? String ?? "N/A"
        let confidence = innerJson["confidence"] as? String ?? "LOW"
        
        return SecurityFinding(
            title: title,
            category: checkCategory,
            severity: severity,
            evidence: [evidence],
            explanation: explanation,
            impact: impact,
            remediation: remediation,
            verification: verification,
            confidence: confidence
        )
    }
    
    func askAdvisor(question: String, findings: [SecurityFinding]) async throws -> String {
        let findingsContext = findings.map { finding in
            "[\(finding.severity.rawValue)] \(finding.title): \(finding.explanation) | Fix: \(finding.remediation)"
        }.joined(separator: "\n")
        
        let prompt = """
        You are a Defensive macOS Security Advisor. The user is asking a question about their recent security audit.
        Be extremely helpful, concise, and beginner-friendly. Answer directly.
        Do NOT hallucinate. Use only the provided audit context and your knowledge of macOS security.
        
        CURRENT FINDINGS:
        \(findingsContext.isEmpty ? "No issues found." : findingsContext)
        
        USER QUESTION: \(question)
        """
        
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You are a macOS security advisor for beginners. Be clear, concise, and helpful. Use markdown formatting."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.2,
            "max_tokens": 512
        ]
        
        guard let apiKey = getAPIKey() else {
            return "API Key missing. Cannot consult the advisor."
        }
        
        let data = try await performRequest(payload: payload, apiKey: apiKey)
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let contentString = (message["content"] as? String) ?? (message["reasoning_content"] as? String) ?? "No advice returned."
        
        return contentString
    }
    
    private func performRequest(payload: [String: Any], apiKey: String, timeout: TimeInterval = 120.0) async throws -> Data {
        let maxRetries = 3
        var lastError: Error?
        var lastResponse: HTTPURLResponse?
        
        for attempt in 0...maxRetries {
            if attempt > 0 {
                // Exponential backoff: 2s, 4s, 8s
                let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
            }
            
            var request = URLRequest(url: invokeUrl)
            request.timeoutInterval = timeout
            request.httpMethod = "POST"
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.addValue("application/json", forHTTPHeaderField: "Accept")
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            
            do {
                let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                    group.addTask {
                        return try await URLSession.shared.data(for: request)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        throw URLError(.timedOut)
                    }
                    guard let result = try await group.next() else {
                        throw URLError(.unknown)
                    }
                    group.cancelAll()
                    return result
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                
                if httpResponse.statusCode == 200 {
                    return data
                }
                
                lastResponse = httpResponse
                
                let errorBody = String(data: data, encoding: .utf8) ?? "No body"
                if httpResponse.statusCode == 429 || (500...599).contains(httpResponse.statusCode) {
                    throw NSError(domain: "LLMService_Retry", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Retryable error"])
                } else if httpResponse.statusCode == 401 {
                    throw NSError(domain: "LLMService_Fatal", code: 401, userInfo: [NSLocalizedDescriptionKey: "Authentication failed. Error: \(errorBody)"])
                } else {
                    throw NSError(domain: "LLMService_Fatal", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "NVIDIA API error (HTTP \(httpResponse.statusCode)): \(errorBody)"])
                }
            } catch {
                lastError = error
                
                // Immediately throw fatal errors instead of retrying
                if let nsError = error as NSError?, nsError.domain == "LLMService_Fatal" {
                    throw error
                }
                // Immediately throw if the overarching task was cancelled
                if error is CancellationError {
                    throw error
                }
            }
        }
        
        if lastResponse != nil, let lastErr = lastError {
            throw lastErr
        }
        
        throw lastError ?? URLError(.badServerResponse)
    }
}
