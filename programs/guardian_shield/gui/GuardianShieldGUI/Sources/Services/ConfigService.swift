import Foundation

class ConfigService {
    private let configPaths = [
        "/etc/warden/warden-config.json",
        "/etc/warden/macwarden.conf",
        NSHomeDirectory() + "/.guardian/config.json"
    ]

    func loadConfig() -> GuardianConfig? {
        // Try JSON config first
        for path in configPaths where path.hasSuffix(".json") {
            if let config = loadJSONConfig(from: path) {
                return config
            }
        }

        // Try line-based macwarden.conf
        if let config = loadMacWardenConfig() {
            return config
        }

        // Return default config
        return GuardianConfig()
    }

    private func loadJSONConfig(from path: String) -> GuardianConfig? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }

        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            var config = GuardianConfig()

            if let global = json?["global"] as? [String: Any] {
                config.enabled = global["enabled"] as? Bool ?? true
                config.logLevel = global["log_level"] as? String ?? "normal"
            }

            if let protection = json?["protection"] as? [String: Any] {
                if let paths = protection["protected_paths"] as? [[String: Any]] {
                    config.protectedPaths = paths.compactMap { dict in
                        guard let path = dict["path"] as? String else { return nil }
                        return ProtectedPath(
                            path: path,
                            description: dict["description"] as? String ?? "",
                            blockOperations: dict["block_operations"] as? [String] ?? []
                        )
                    }
                }

                if let whitelist = protection["whitelisted_paths"] as? [[String: Any]] {
                    config.whitelistedPaths = whitelist.compactMap { $0["path"] as? String }
                }
            }

            return config
        } catch {
            print("Failed to parse JSON config: \(error)")
            return nil
        }
    }

    private func loadMacWardenConfig() -> GuardianConfig? {
        let path = "/etc/warden/macwarden.conf"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        var config = GuardianConfig()
        var protectedPaths: [ProtectedPath] = []
        var whitelistedPaths: [String] = []

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "enabled":
                config.enabled = value.lowercased() == "true"
            case "protected":
                protectedPaths.append(ProtectedPath(path: value))
            case "whitelist":
                whitelistedPaths.append(value)
            default:
                break
            }
        }

        config.protectedPaths = protectedPaths
        config.whitelistedPaths = whitelistedPaths

        return config
    }

    func saveConfig(_ config: GuardianConfig) -> Bool {
        let configDir = NSHomeDirectory() + "/.guardian"
        let configPath = configDir + "/config.json"

        // Ensure directory exists
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: URL(fileURLWithPath: configPath))
            return true
        } catch {
            print("Failed to save config: \(error)")
            return false
        }
    }

    func reloadDaemon() {
        // Send SIGHUP to reload config
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-HUP", "libwarden"]
        try? task.run()
    }
}
