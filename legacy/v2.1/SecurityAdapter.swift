import Foundation

protocol SecurityTool {
    var identifier: String { get }
    var name: String { get }
    var description: String { get }
}

protocol SecurityAdapter: SecurityTool {
    var category: String { get }
    
    func validate(scope: SecurityScope) async throws
    func execute(scope: SecurityScope) async throws -> [SecurityObservation]
}
