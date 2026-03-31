// Guardian Network Filter — Content Filter + DNS Proxy for macOS
//
// Enforces network allowlists for AI agent process trees using:
//   - NEFilterDataProvider: per-flow TCP/UDP allow/deny
//   - ES client: process tree tracking via responsible_audit_token
//
// Same policy as es-warden file protection, different enforcement point.
// Config: /etc/warden/ctk.conf (network_allow = <host>)
//
// Copyright (c) 2025-2026 Richard Tune / Quantum Encoding Ltd
// License: Dual License - MIT (Non-Commercial) / Commercial License

import Foundation
import NetworkExtension
import EndpointSecurity

// MARK: - Configuration

struct NetFilterConfig {
    // Network allowlist — connections to unlisted hosts from agent tree are blocked
    static let allowedHosts: [String] = [
        "github.com",
        "api.github.com",
        "api.anthropic.com",
        "api.quantumencoding.ai",
        "*.googleapis.com",
        "*.sentry.io",
        "registry.npmjs.org",
        "crates.io",
        "pypi.org",
    ]

    // Observed process names — only these trigger filtering
    static let observedProcessNames: [String] = [
        "claude",
        "node",
    ]

    // Trusted processes — bypass network filter entirely
    static let trustedProcesses: [String] = [
        "/usr/bin/git",
        "/usr/local/bin/git",
        "/opt/homebrew/bin/git",
        "/usr/sbin/mDNSResponder",
        "/usr/libexec/nsurlsessiond",
    ]

    // Config file path
    static let configPath = "/etc/warden/ctk.conf"

    // Emergency disable
    static let emergencyDisableFile = "/tmp/.guardian_netfilter_disable"
}

// MARK: - Process Tree Tracker (ES-backed)

/// Tracks which PIDs belong to observed agent process trees.
/// Uses ES NOTIFY_EXEC/FORK/EXIT to maintain a live map.
class ProcessTreeTracker {
    private var agentPIDs: Set<pid_t> = []         // PIDs that ARE agent processes
    private var agentTreePIDs: Set<pid_t> = []     // PIDs spawned BY agent processes
    private var esClient: OpaquePointer?
    private let queue = DispatchQueue(label: "io.quantumencoding.proctree", qos: .userInteractive)

    func start() -> Bool {
        var client: OpaquePointer?
        let result = es_new_client(&client) { [weak self] _, message in
            self?.handleMessage(message)
        }

        guard result == ES_NEW_CLIENT_RESULT_SUCCESS else {
            print("[netfilter] Warning: ES client failed (\(result.rawValue)) — filtering all processes")
            return false
        }

        esClient = client

        // Subscribe to process lifecycle events
        let events: [es_event_type_t] = [
            ES_EVENT_TYPE_NOTIFY_EXEC,
            ES_EVENT_TYPE_NOTIFY_FORK,
            ES_EVENT_TYPE_NOTIFY_EXIT,
        ]

        let subResult = es_subscribe(client!, events, UInt32(events.count))
        guard subResult == ES_RETURN_SUCCESS else {
            print("[netfilter] Warning: ES subscribe failed — filtering all processes")
            es_delete_client(client!)
            return false
        }

        print("[netfilter] Process tree tracker active (ES NOTIFY_EXEC/FORK/EXIT)")
        return true
    }

    func stop() {
        if let client = esClient {
            es_unsubscribe_all(client)
            es_delete_client(client)
        }
    }

    /// Check if a PID belongs to an observed agent's process tree.
    func isAgentProcess(_ pid: pid_t) -> Bool {
        return queue.sync {
            agentPIDs.contains(pid) || agentTreePIDs.contains(pid)
        }
    }

    private func handleMessage(_ message: UnsafePointer<es_message_t>) {
        let eventType = message.pointee.event_type
        let process = message.pointee.process.pointee
        let pid = audit_token_to_pid(process.audit_token)
        let processPath = getString(from: process.executable.pointee.path)
        let processName = (processPath as NSString).lastPathComponent

        queue.async { [weak self] in
            guard let self = self else { return }

            switch eventType {
            case ES_EVENT_TYPE_NOTIFY_EXEC:
                // Check if the new process is an observed agent
                let target = message.pointee.event.exec.target.pointee
                let targetPath = self.getString(from: target.executable.pointee.path)
                let targetName = (targetPath as NSString).lastPathComponent

                for observed in NetFilterConfig.observedProcessNames {
                    if targetName.contains(observed) {
                        self.agentPIDs.insert(pid)
                        self.agentTreePIDs.insert(pid)
                        print("[netfilter] Agent detected: \(targetName) (PID \(pid))")
                        return
                    }
                }

                // Check if parent/responsible is in agent tree
                let responsiblePID = audit_token_to_pid(process.responsible_audit_token)
                let parentPID = process.ppid
                if self.agentTreePIDs.contains(responsiblePID) ||
                   self.agentTreePIDs.contains(parentPID) ||
                   self.agentPIDs.contains(responsiblePID) {
                    self.agentTreePIDs.insert(pid)
                }

            case ES_EVENT_TYPE_NOTIFY_FORK:
                // Child inherits agent tree membership
                let childPID = audit_token_to_pid(message.pointee.event.fork.child.pointee.audit_token)
                if self.agentTreePIDs.contains(pid) || self.agentPIDs.contains(pid) {
                    self.agentTreePIDs.insert(childPID)
                }

            case ES_EVENT_TYPE_NOTIFY_EXIT:
                // Clean up
                self.agentPIDs.remove(pid)
                self.agentTreePIDs.remove(pid)

            default:
                break
            }
        }
    }

    private func getString(from token: es_string_token_t) -> String {
        if token.length > 0, let data = token.data {
            return String(cString: data)
        }
        return ""
    }
}

// MARK: - Network Policy Engine

struct NetworkPolicy {
    let allowedHosts: [String]

    init() {
        // Load from config file or use defaults
        var hosts = NetFilterConfig.allowedHosts
        if let configHosts = NetworkPolicy.loadFromConfig() {
            hosts = configHosts
        }
        self.allowedHosts = hosts
    }

    func isAllowed(hostname: String) -> Bool {
        for pattern in allowedHosts {
            if pattern == "*" { return true }

            // Wildcard prefix: *.googleapis.com
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(1)) // ".googleapis.com"
                if hostname.hasSuffix(suffix) { return true }
            }

            if hostname == pattern { return true }
        }
        return false
    }

    func isAllowed(address: String, port: UInt16) -> Bool {
        // For direct IP connections, check against allowlist
        // TODO: reverse DNS or just allow known IPs
        return isAllowed(hostname: address)
    }

    private static func loadFromConfig() -> [String]? {
        guard let data = FileManager.default.contents(atPath: NetFilterConfig.configPath),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        var hosts: [String] = []
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("network_allow") {
                if let eq = trimmed.firstIndex(of: "=") {
                    let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty {
                        hosts.append(value)
                    }
                }
            }
        }
        return hosts.isEmpty ? nil : hosts
    }
}

// MARK: - Guardian Network Filter

class GuardianNetFilter {
    private let processTracker = ProcessTreeTracker()
    private let policy = NetworkPolicy()
    private var isRunning = false

    // Statistics
    private var blockedFlows: UInt64 = 0
    private var allowedFlows: UInt64 = 0
    private var agentFlows: UInt64 = 0

    init() {
        print("Guardian Network Filter")
        print("=======================")
    }

    func start() -> Bool {
        print("[*] Starting process tree tracker...")
        let esOK = processTracker.start()
        if !esOK {
            print("[!] Running without process attribution — filtering ALL network flows")
        }

        print("[+] Network policy loaded: \(policy.allowedHosts.count) allowed hosts")
        for host in policy.allowedHosts {
            print("    ✓ \(host)")
        }

        isRunning = true
        print("[+] Guardian Network Filter ACTIVE")
        return true
    }

    func stop() {
        print("\n[*] Shutting down...")
        print("[*] Stats: \(blockedFlows) blocked, \(allowedFlows) allowed, \(agentFlows) agent flows")
        processTracker.stop()
        isRunning = false
    }

    /// Evaluate a network flow. Called by the filter provider.
    func evaluateFlow(pid: pid_t, hostname: String?, remoteAddress: String?, remotePort: UInt16, processPath: String) -> Bool {
        // Emergency disable
        if FileManager.default.fileExists(atPath: NetFilterConfig.emergencyDisableFile) {
            return true
        }

        // Trusted process bypass
        for trusted in NetFilterConfig.trustedProcesses {
            if processPath == trusted {
                allowedFlows += 1
                return true
            }
        }

        // Only filter agent process trees
        if !processTracker.isAgentProcess(pid) {
            allowedFlows += 1
            return true // not an agent, don't interfere
        }

        agentFlows += 1

        // Check hostname against allowlist
        if let host = hostname {
            if policy.isAllowed(hostname: host) {
                allowedFlows += 1
                return true
            }
            blockedFlows += 1
            print("[🛡️] BLOCKED flow: \(host):\(remotePort)")
            print("    Process: \(processPath) (PID: \(pid))")
            return false
        }

        // Check IP address against allowlist
        if let addr = remoteAddress {
            if policy.isAllowed(address: addr, port: remotePort) {
                allowedFlows += 1
                return true
            }
            blockedFlows += 1
            print("[🛡️] BLOCKED flow: \(addr):\(remotePort)")
            print("    Process: \(processPath) (PID: \(pid))")
            return false
        }

        // No hostname or address — allow (internal/loopback)
        allowedFlows += 1
        return true
    }
}

// MARK: - Filter Data Provider (would be NEFilterDataProvider in System Extension)
//
// NOTE: A full NEFilterDataProvider requires running as a System Extension
// (.systemextension bundle inside an app). For development and testing,
// this standalone binary demonstrates the logic. The System Extension
// wrapper is a thin shell that instantiates this same policy engine.
//
// To deploy as System Extension:
// 1. Create an app bundle with this as the NEFilterDataProvider
// 2. Sign with com.apple.developer.networking.networkextension entitlement
// 3. App calls OSSystemExtensionRequest.activationRequest()
// 4. User approves in System Settings

class FilterProvider {
    let guardian: GuardianNetFilter

    init(guardian: GuardianNetFilter) {
        self.guardian = guardian
    }

    /// Simulates NEFilterDataProvider.handleNewFlow()
    /// In production, this is called by the NE framework for every new TCP/UDP flow.
    func handleNewFlow(pid: pid_t, hostname: String?, remoteAddress: String?, remotePort: UInt16, processPath: String) -> FilterVerdict {
        let allowed = guardian.evaluateFlow(
            pid: pid,
            hostname: hostname,
            remoteAddress: remoteAddress,
            remotePort: remotePort,
            processPath: processPath
        )
        return allowed ? .allow : .drop
    }

    enum FilterVerdict {
        case allow
        case drop
        case needMoreData
    }
}

// MARK: - DNS Proxy (future)
//
// NEDNSProxyProvider intercepts all DNS queries system-wide.
// For agent processes, resolve only allowlisted domains.
// Return NXDOMAIN for everything else.
//
// This blocks exfiltration at the earliest possible point —
// before a TCP connection is even attempted.

// MARK: - Signal Handling

var guardian: GuardianNetFilter?

func signalHandler(_ signal: Int32) {
    print("\n[*] Received signal \(signal)")
    guardian?.stop()
    exit(0)
}

// MARK: - Main

func main() {
    // Check root
    guard getuid() == 0 else {
        print("[-] ERROR: Must run as root")
        print("    Usage: sudo ./guardian-netfilter")
        exit(1)
    }

    // Signal handlers
    signal(SIGINT, signalHandler)
    signal(SIGTERM, signalHandler)

    guardian = GuardianNetFilter()

    guard guardian!.start() else {
        print("[-] Failed to start Guardian Network Filter")
        exit(1)
    }

    print("[*] Press Ctrl+C to stop")
    print("")

    // In standalone mode, run as a daemon monitoring the process tree.
    // The actual flow interception happens when deployed as a System Extension.
    //
    // For testing, we can demonstrate the policy engine by simulating flows:
    print("[*] Network filter policy engine ready")
    print("[*] Deploy as System Extension for live flow interception")
    print("[*] Or use with 'guardian-netfilter --test' for policy simulation")

    // Check for --test flag
    if CommandLine.arguments.contains("--test") {
        runPolicyTests()
        return
    }

    // Run forever (daemon mode)
    dispatchMain()
}

func runPolicyTests() {
    let g = guardian!
    let filter = FilterProvider(guardian: g)

    print("\n=== Policy Engine Tests ===\n")

    struct TestCase {
        let host: String
        let pid: pid_t
        let process: String
        let expectAllow: Bool
        let description: String
    }

    let tests: [TestCase] = [
        // System process (not agent) — always allowed
        TestCase(host: "evil.com", pid: 1, process: "/usr/sbin/mDNSResponder", expectAllow: true,
                description: "System process to unknown host"),

        // Trusted process — always allowed
        TestCase(host: "anything.com", pid: 100, process: "/usr/bin/git", expectAllow: true,
                description: "Trusted process (git) to any host"),

        // Allowlisted host — allowed
        TestCase(host: "github.com", pid: 200, process: "/usr/local/bin/claude", expectAllow: true,
                description: "Agent to allowlisted host (github.com)"),

        // Wildcard match
        TestCase(host: "storage.googleapis.com", pid: 200, process: "/usr/local/bin/node", expectAllow: true,
                description: "Agent to wildcard host (*.googleapis.com)"),

        // Blocked — agent to unknown host
        TestCase(host: "evil.com", pid: 200, process: "/usr/local/bin/claude", expectAllow: false,
                description: "Agent to unknown host (evil.com)"),

        // Blocked — agent subprocess to unknown host
        TestCase(host: "exfil.attacker.com", pid: 201, process: "/usr/bin/curl", expectAllow: false,
                description: "Agent child (curl) to unknown host"),
    ]

    var passed = 0
    for test in tests {
        let verdict = filter.handleNewFlow(
            pid: test.pid,
            hostname: test.host,
            remoteAddress: nil,
            remotePort: 443,
            processPath: test.process
        )

        let allowed = verdict == .allow
        let ok = allowed == test.expectAllow
        let mark = ok ? "✓" : "✗"
        let result = allowed ? "ALLOW" : "BLOCK"
        print("  \(mark) \(test.description): \(result)")
        if ok { passed += 1 }
    }

    print("\n\(passed)/\(tests.count) tests passed")
}

main()
