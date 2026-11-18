#if canImport(XCTest)
import XCTest
#else
import Foundation
public func XCTAssertEqual<T: Equatable>(_ expression1: @autoclosure () -> T, _ expression2: @autoclosure () -> T, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    let e1 = expression1()
    let e2 = expression2()
    if e1 != e2 {
        print("❌ Test failed at \(file):\(line): \(e1) is not equal to \(e2)")
        exit(1)
    }
}
public func XCTAssertTrue(_ expression: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    if !expression() {
        print("❌ Test failed at \(file):\(line): \(message())")
        exit(1)
    }
}
public func XCTAssertFalse(_ expression: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    if expression() {
        print("❌ Test failed at \(file):\(line): \(message())") 
        exit(1)
    }
}
open class XCTestCase {
    public init() {}
    open func setUp() {}
    open func tearDown() {}
}
#endif

import Foundation

// MARK: - CommandExecutor Tests

class CommandExecutorTests: XCTestCase {
    func testExecuteSuccess() {
        let result = CommandExecutor.execute(executable: "echo", arguments: ["Hello"])
        XCTAssertEqual(result.stdout, "Hello")
        XCTAssertTrue(result.success, "echo should succeed")
    }
    
    func testExecuteError() {
        let result = CommandExecutor.execute(executable: "cat", arguments: ["/nonexistent_file_for_test"])
        XCTAssertFalse(result.success, "cat nonexistent should fail")
        XCTAssertTrue(result.stderr.contains("No such file") || result.exitCode != 0, "should report error")
    }
    
    func testExecuteEmpty() {
        let result = CommandExecutor.execute(executable: "true", arguments: [])
        XCTAssertTrue(result.success, "true should succeed")
    }
    
    func testLegacyExecute() {
        let output = CommandExecutor.execute("echo Hello")
        XCTAssertEqual(output, "Hello")
    }
}

// MARK: - CommandValidator Tests

class CommandValidatorTests: XCTestCase {
    func testLowRiskCommand() {
        let result = CommandValidator.validate("ps aux")
        switch result {
        case .success(let validated):
            XCTAssertEqual(validated.executable, "ps")
            XCTAssertEqual(validated.risk.rawValue, "LOW")
            XCTAssertFalse(validated.requiresConfirmation, "low risk should not need confirmation")
        case .failure:
            XCTAssertTrue(false, "ps aux should not fail validation")
        }
    }
    
    func testBlockedCommand() {
        let result = CommandValidator.validate("rm -rf /")
        switch result {
        case .success:
            XCTAssertTrue(false, "rm should fail validation")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("blocked"), "should report blocked executable")
        }
    }
    
    func testHighRiskCommand() {
        let result = CommandValidator.validate("mv foo bar")
        switch result {
        case .success(let validated):
            XCTAssertEqual(validated.risk.rawValue, "HIGH")
            XCTAssertTrue(validated.requiresConfirmation, "high risk should require confirmation")
        case .failure:
            XCTAssertTrue(false, "mv should be high risk, not blocked")
        }
    }
    
    func testShellInjection() {
        let result = CommandValidator.validate("ls; rm -rf /")
        switch result {
        case .success:
            XCTAssertTrue(false, "shell injection should fail validation")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("injection"), "should report injection")
        }
    }
    
    func testQuotedArguments() {
        let result = CommandValidator.validate("echo \"Hello World\"")
        switch result {
        case .success(let validated):
            XCTAssertEqual(validated.executable, "echo")
            XCTAssertEqual(validated.arguments, ["Hello World"])
        case .failure:
            XCTAssertTrue(false, "quoted echo should not fail")
        }
    }
    
    func testUnknownExecutable() {
        let result = CommandValidator.validate("mytool --flag")
        switch result {
        case .success(let validated):
            XCTAssertEqual(validated.risk.rawValue, "MODERATE")
            XCTAssertTrue(validated.requiresConfirmation, "unknown should require confirmation")
        case .failure:
            XCTAssertTrue(false, "unknown should default to moderate, not fail")
        }
    }
    
    func testEmptyCommand() {
        let result = CommandValidator.validate("   ")
        switch result {
        case .success:
            XCTAssertTrue(false, "empty should fail")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("empty"), "should report empty")
        }
    }
}

// MARK: - ProcessManager Tests

class ProcessManagerTests: XCTestCase {
    func testParsePSOutput() {
        let manager = ProcessManager()
        
        let mockOutput = """
          123  5.0 10240 Safari
          456 12.3  2048 Code
        """
        
        let processes = manager.parsePSOutput(mockOutput)
        
        XCTAssertEqual(processes.count, 2)
        XCTAssertEqual(processes[0].pid, "123")
        XCTAssertEqual(processes[0].name, "Safari")
        XCTAssertEqual(processes[1].pid, "456")
        XCTAssertEqual(processes[1].name, "Code")
    }
    
    func testParsePSOutputEmpty() {
        let manager = ProcessManager()
        let processes = manager.parsePSOutput("")
        XCTAssertEqual(processes.count, 0)
    }
    
    func testParsePSOutputMalformed() {
        let manager = ProcessManager()
        let processes = manager.parsePSOutput("malformed data\n\n  123")
        // Should not crash, should skip bad lines
        XCTAssertEqual(processes.count, 0)
    }
}
class SecurityModelsTests {
    func setUp() {}
    func tearDown() {}
    
    func testSeverityComparison() {
        XCTAssertEqual(SecuritySeverity.info < SecuritySeverity.low, true, "Info should be less than low")
        XCTAssertEqual(SecuritySeverity.critical > SecuritySeverity.high, true, "Critical should be greater than high")
    }
    
    func testOverallScore() {
        var session = SecurityAuditSession()
        session.checksPerformed = 2
        
        XCTAssertEqual(session.overallScore, 100, "Score should be 100 with no findings")
        
        let finding1 = SecurityFinding(title: "Test1", category: "Test", severity: .low, evidence: [], explanation: "", impact: "", remediation: "", verification: "", confidence: "")
        let finding2 = SecurityFinding(title: "Test2", category: "Test", severity: .high, evidence: [], explanation: "", impact: "", remediation: "", verification: "", confidence: "")
        
        session.findings = [finding1, finding2]
        
        XCTAssertEqual(session.overallScore, 100 - 2 - 15, "Score should reflect penalty for low and high findings")
    }
}

// MARK: - NetworkScanner Tests

class NetworkScannerTests {
    func testDeviceInitialization() {
        let device = NetworkDevice(ipAddress: "192.168.1.10", hostname: "TestHost", isGateway: false, isLocalHost: true)
        XCTAssertEqual(device.ipAddress, "192.168.1.10")
        XCTAssertEqual(device.hostname, "TestHost")
        XCTAssertTrue(device.isLocalHost)
        XCTAssertFalse(device.isGateway)
        XCTAssertEqual(device.status, .online)
    }
    
    func testScanSession() {
        var session = NetworkScanSession(subnet: "192.168.1")
        XCTAssertEqual(session.subnet, "192.168.1")
        XCTAssertFalse(session.isScanning)
        XCTAssertEqual(session.devices.count, 0)
        
        let port = PortResult(port: 80, isOpen: true, service: "HTTP")
        let dev = NetworkDevice(ipAddress: "192.168.1.1", hostname: "Router", openPorts: [port], isGateway: true)
        session.devices.append(dev)
        XCTAssertEqual(session.devices.count, 1)
        XCTAssertEqual(session.devices[0].openPorts.count, 1)
        XCTAssertEqual(session.devices[0].openPorts[0].service, "HTTP")
    }
}

// MARK: - Test Suite Runner Entry Point

@main
struct TestRunner {
    static func main() {
        print("🧪 Running HackCode Test Suite...")

        let executorTests = CommandExecutorTests()
        executorTests.testExecuteSuccess()
        executorTests.testExecuteError()
        executorTests.testExecuteEmpty()
        executorTests.testLegacyExecute()
        print("  ✅ CommandExecutorTests passed")

        let validatorTests = CommandValidatorTests()
        validatorTests.testLowRiskCommand()
        validatorTests.testBlockedCommand()
        validatorTests.testHighRiskCommand()
        validatorTests.testShellInjection()
        validatorTests.testQuotedArguments()
        validatorTests.testUnknownExecutable()
        validatorTests.testEmptyCommand()
        print("  ✅ CommandValidatorTests passed")

        let processTests = ProcessManagerTests()
        processTests.testParsePSOutput()
        processTests.testParsePSOutputEmpty()
        processTests.testParsePSOutputMalformed()
        print("  ✅ ProcessManagerTests passed")

        let modelTests = SecurityModelsTests()
        modelTests.testSeverityComparison()
        modelTests.testOverallScore()
        print("  ✅ SecurityModelsTests passed")

        let networkTests = NetworkScannerTests()
        networkTests.testDeviceInitialization()
        networkTests.testScanSession()
        print("  ✅ NetworkScannerTests passed")

        let slashTests = SlashCommandRegistryTests()
        slashTests.testRegistryContainsAuditCommands()
        slashTests.testFilterByCategory()
        slashTests.testFilterByQuery()
        slashTests.testCommandProperties()
        print("  ✅ SlashCommandRegistryTests passed")

        print("🎉 All 6 test suites passed successfully!")
    }
}

// MARK: - SlashCommandRegistry Tests

class SlashCommandRegistryTests {
    func testRegistryContainsAuditCommands() {
        let items = SlashCommandRegistry.shared.allCommands
        XCTAssertTrue(items.count >= 20, "Should have 20+ slash commands registered")
        
        let commandNames = items.map { $0.command }
        XCTAssertTrue(commandNames.contains("/audit"), "Should contain /audit")
        XCTAssertTrue(commandNames.contains("/audit-firewall"), "Should contain /audit-firewall")
        XCTAssertTrue(commandNames.contains("/audit-sip"), "Should contain /audit-sip")
        XCTAssertTrue(commandNames.contains("/audit-secrets"), "Should contain /audit-secrets")
        XCTAssertTrue(commandNames.contains("/audit-ports"), "Should contain /audit-ports")
        XCTAssertTrue(commandNames.contains("/remediate"), "Should contain /remediate")
        XCTAssertTrue(commandNames.contains("/report"), "Should contain /report")
        XCTAssertTrue(commandNames.contains("/status"), "Should contain /status")
        XCTAssertTrue(commandNames.contains("/help"), "Should contain /help")
        XCTAssertTrue(commandNames.contains("/advisor"), "Should contain /advisor")
    }
    
    func testFilterByCategory() {
        let auditItems = SlashCommandRegistry.shared.filter(query: "", category: .audits)
        XCTAssertTrue(auditItems.allSatisfy { $0.category == .audits }, "All filtered items should be audits")
        XCTAssertTrue(auditItems.count >= 10, "Should have at least 10 audit commands")
        
        let actionItems = SlashCommandRegistry.shared.filter(query: "", category: .actions)
        XCTAssertTrue(actionItems.allSatisfy { $0.category == .actions }, "All filtered items should be actions")
        
        let systemItems = SlashCommandRegistry.shared.filter(query: "", category: .system)
        XCTAssertTrue(systemItems.allSatisfy { $0.category == .system }, "All filtered items should be system")
        
        let allItems = SlashCommandRegistry.shared.filter(query: "", category: .all)
        XCTAssertEqual(allItems.count, SlashCommandRegistry.shared.allCommands.count, "All category should return all items")
    }
    
    func testFilterByQuery() {
        let firewallResults = SlashCommandRegistry.shared.filter(query: "firewall")
        XCTAssertTrue(!firewallResults.isEmpty, "Should find firewall audit command")
        XCTAssertEqual(firewallResults.first?.command, "/audit-firewall")
        
        let portResults = SlashCommandRegistry.shared.filter(query: "ports")
        XCTAssertTrue(!portResults.isEmpty, "Should find ports audit command")
        XCTAssertEqual(portResults.first?.command, "/audit-ports")
        
        let slashPrefixed = SlashCommandRegistry.shared.filter(query: "/sip")
        XCTAssertTrue(!slashPrefixed.isEmpty, "Should find sip command when leading slash is typed")
        XCTAssertEqual(slashPrefixed.first?.command, "/audit-sip")
        
        let emptyQuery = SlashCommandRegistry.shared.filter(query: "")
        XCTAssertEqual(emptyQuery.count, SlashCommandRegistry.shared.allCommands.count, "Empty query returns all")
    }
    
    func testCommandProperties() {
        let items = SlashCommandRegistry.shared.allCommands
        guard let firewallCmd = items.first(where: { $0.command == "/audit-firewall" }) else {
            XCTAssertTrue(false, "Could not find /audit-firewall item")
            return
        }
        XCTAssertEqual(firewallCmd.category, .audits)
        XCTAssertFalse(firewallCmd.requiresArgs)
        XCTAssertFalse(firewallCmd.description.isEmpty)
        XCTAssertFalse(firewallCmd.syntax.isEmpty)
        XCTAssertEqual(firewallCmd.risk, "AUDIT")
    }
}

