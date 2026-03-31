import Foundation

class EventMonitor {
    private let logPaths = [
        "/tmp/guardian-shield.log",
        "/var/log/warden/blocks.log",
        "/tmp/warden-blocks.log"
    ]

    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private let callback: (BlockEvent) -> Void

    init(callback: @escaping (BlockEvent) -> Void) {
        self.callback = callback
    }

    func startMonitoring() {
        // Find first available log file
        for path in logPaths {
            if FileManager.default.fileExists(atPath: path) {
                monitorFile(at: path)
                return
            }
        }

        // If no file exists, create and monitor the first one
        let defaultPath = logPaths[0]
        FileManager.default.createFile(atPath: defaultPath, contents: nil)
        monitorFile(at: defaultPath)
    }

    private func monitorFile(at path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            print("Cannot open log file: \(path)")
            return
        }

        fileHandle = handle

        // Seek to end to only get new events
        handle.seekToEndOfFile()

        // Set up file system event monitoring
        let fd = handle.fileDescriptor
        let queue = DispatchQueue(label: "guardian.eventmonitor")

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )

        source?.setEventHandler { [weak self] in
            self?.readNewContent()
        }

        source?.setCancelHandler { [weak self] in
            self?.fileHandle?.closeFile()
        }

        source?.resume()

        print("Monitoring: \(path)")
    }

    private func readNewContent() {
        guard let handle = fileHandle else { return }

        let data = handle.availableData
        guard !data.isEmpty,
              let content = String(data: data, encoding: .utf8) else {
            return
        }

        for line in content.components(separatedBy: .newlines) {
            guard !line.isEmpty else { continue }

            // Try JSON parsing first
            if line.hasPrefix("{"),
               let jsonData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let event = BlockEvent.fromJSON(json) {
                callback(event)
                continue
            }

            // Fall back to log line parsing
            if let event = BlockEvent.fromLogLine(line) {
                callback(event)
            }
        }
    }

    func stopMonitoring() {
        source?.cancel()
        source = nil
        fileHandle = nil
    }

    deinit {
        stopMonitoring()
    }
}

// MARK: - SurrealDB Monitor (alternative)
class SurrealDBMonitor {
    private let url: URL
    private var timer: Timer?
    private var lastTimestamp: TimeInterval = 0
    private let callback: (BlockEvent) -> Void

    init(url: String = "http://127.0.0.1:8000/sql", callback: @escaping (BlockEvent) -> Void) {
        self.url = URL(string: url)!
        self.callback = callback
    }

    func startPolling(interval: TimeInterval = 2.0) {
        lastTimestamp = Date().timeIntervalSince1970

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetchNewEvents()
        }
    }

    private func fetchNewEvents() {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Basic cm9vdDpyb290", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")

        let query = """
        USE NS guardian DB shield;
        SELECT * FROM block_event WHERE timestamp > \(lastTimestamp) ORDER BY timestamp DESC LIMIT 50;
        """
        request.httpBody = query.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self,
                  let data = data,
                  error == nil else { return }

            do {
                if let response = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                   let result = response.last?["result"] as? [[String: Any]] {
                    for eventData in result {
                        if let event = BlockEvent.fromJSON(eventData) {
                            DispatchQueue.main.async {
                                self.callback(event)
                            }
                            if let ts = eventData["timestamp"] as? TimeInterval, ts > self.lastTimestamp {
                                self.lastTimestamp = ts
                            }
                        }
                    }
                }
            } catch {
                print("Failed to parse SurrealDB response: \(error)")
            }
        }.resume()
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}
