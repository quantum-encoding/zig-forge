import Foundation

struct BlockEvent: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let operation: String
    let path: String
    let process: String?
    let pid: Int?
    let severity: Severity

    enum Severity: String, Codable {
        case low
        case medium
        case high
        case critical

        var color: String {
            switch self {
            case .low: return "green"
            case .medium: return "yellow"
            case .high: return "orange"
            case .critical: return "red"
            }
        }
    }

    init(id: UUID = UUID(), timestamp: Date = Date(), operation: String, path: String, process: String? = nil, pid: Int? = nil, severity: Severity = .medium) {
        self.id = id
        self.timestamp = timestamp
        self.operation = operation
        self.path = path
        self.process = process
        self.pid = pid
        self.severity = severity
    }

    // Parse from log line: "[libwarden.so] BLOCKED unlink: /etc/passwd"
    static func fromLogLine(_ line: String) -> BlockEvent? {
        // Pattern: [libwarden.so] <emoji> BLOCKED <operation>: <path>
        let pattern = #"BLOCKED\s+(\w+):\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }

        guard let opRange = Range(match.range(at: 1), in: line),
              let pathRange = Range(match.range(at: 2), in: line) else {
            return nil
        }

        let operation = String(line[opRange])
        let path = String(line[pathRange])

        // Determine severity based on path
        let severity: Severity
        if path.hasPrefix("/etc") || path.hasPrefix("/System") {
            severity = .critical
        } else if path.contains(".git") || path.hasPrefix("/usr") {
            severity = .high
        } else if path.hasPrefix("/tmp") {
            severity = .low
        } else {
            severity = .medium
        }

        return BlockEvent(operation: operation, path: path, severity: severity)
    }

    // Parse from JSON
    static func fromJSON(_ json: [String: Any]) -> BlockEvent? {
        guard let operation = json["type"] as? String ?? json["operation"] as? String,
              let path = json["path"] as? String else {
            return nil
        }

        let timestamp: Date
        if let ts = json["timestamp"] as? TimeInterval {
            timestamp = Date(timeIntervalSince1970: ts)
        } else {
            timestamp = Date()
        }

        let severityStr = json["severity"] as? String ?? "medium"
        let severity = Severity(rawValue: severityStr) ?? .medium

        return BlockEvent(
            timestamp: timestamp,
            operation: operation,
            path: path,
            process: json["process"] as? String,
            pid: json["pid"] as? Int,
            severity: severity
        )
    }
}

struct ProtectedPath: Identifiable, Codable {
    let id: UUID
    var path: String
    var description: String
    var blockOperations: [String]

    init(id: UUID = UUID(), path: String, description: String = "", blockOperations: [String] = ["unlink", "rmdir", "rename"]) {
        self.id = id
        self.path = path
        self.description = description
        self.blockOperations = blockOperations
    }
}

struct GuardianConfig: Codable {
    var enabled: Bool
    var protectedPaths: [ProtectedPath]
    var whitelistedPaths: [String]
    var logLevel: String
    var notificationsEnabled: Bool

    init() {
        enabled = true
        protectedPaths = []
        whitelistedPaths = []
        logLevel = "normal"
        notificationsEnabled = true
    }
}
