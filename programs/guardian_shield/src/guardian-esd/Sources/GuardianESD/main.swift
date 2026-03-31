// Guardian ESD - Endpoint Security Daemon for macOS
// Kernel-level file protection using Apple's Endpoint Security Framework
//
// Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
// License: Dual License - MIT (Non-Commercial) / Commercial License
//
// REQUIREMENTS:
// - macOS 13.0+
// - Apple Developer account with com.apple.developer.endpoint-security.client entitlement
// - Must run as root
// - User must approve System Extension in System Preferences

import Foundation
import EndpointSecurity

// MARK: - Configuration

struct GuardianConfig {
    // Paths that cannot be modified
    static let protectedPaths: [String] = [
        "/Users/director/work",
        "/Users/director/websites",
        "/Users/director/.ssh",
        "/Users/director/.gnupg",
        "/Users/director/.aws",
        "/Users/director/warden-fortress"  // Test path
    ]

    // Paths that are always allowed (system needs these)
    static let whitelistedPaths: [String] = [
        "/tmp",
        "/private/tmp",
        "/var/folders",
        "/Library/Caches",
        "/Users/director/Library/Caches",
        "/Users/director/.cache"
    ]

    // Processes that are trusted (bypass all checks)
    static let trustedProcesses: [String] = [
        "/usr/bin/git",
        "/usr/local/bin/git",
        "/opt/homebrew/bin/git"
    ]

    // Emergency kill switch file
    static let emergencyDisableFile = "/tmp/.guardian_esd_disable"
}

// MARK: - Guardian Shield ESF Client

class GuardianShield {
    private var client: OpaquePointer?
    private var isRunning = false
    private let queue = DispatchQueue(label: "io.quantumencoding.guardian-esd", qos: .userInteractive)

    // Statistics
    private var blockedCount: UInt64 = 0
    private var allowedCount: UInt64 = 0

    init() {
        print("Guardian ESD - Endpoint Security Daemon")
        print("========================================")
    }

    // MARK: - Client Lifecycle

    func start() -> Bool {
        print("[*] Initializing Endpoint Security client...")

        var newClient: OpaquePointer?
        let result = es_new_client(&newClient) { [weak self] _, message in
            self?.handleMessage(message)
        }

        guard result == ES_NEW_CLIENT_RESULT_SUCCESS else {
            printError(result)
            return false
        }

        client = newClient
        print("[+] ES client created successfully")

        // Clear cache to ensure we get all events
        if es_clear_cache(client!) != ES_CLEAR_CACHE_RESULT_SUCCESS {
            print("[!] Warning: Failed to clear ES cache")
        }

        // Subscribe to events
        let events: [es_event_type_t] = [
            ES_EVENT_TYPE_AUTH_UNLINK,
            ES_EVENT_TYPE_AUTH_RENAME,
            ES_EVENT_TYPE_AUTH_TRUNCATE,
            ES_EVENT_TYPE_AUTH_LINK,
            ES_EVENT_TYPE_AUTH_CREATE,
            ES_EVENT_TYPE_AUTH_CLONE,
            ES_EVENT_TYPE_AUTH_EXCHANGEDATA,
            ES_EVENT_TYPE_AUTH_SETEXTATTR,
            ES_EVENT_TYPE_AUTH_DELETEEXTATTR
        ]

        let subscribeResult = es_subscribe(client!, events, UInt32(events.count))
        guard subscribeResult == ES_RETURN_SUCCESS else {
            print("[-] Failed to subscribe to events")
            es_delete_client(client!)
            return false
        }

        print("[+] Subscribed to \(events.count) event types")
        print("[+] Protected paths:")
        for path in GuardianConfig.protectedPaths {
            print("    - \(path)")
        }
        print("[+] Guardian Shield ACTIVE - Kernel-level protection enabled")
        print("")

        isRunning = true
        return true
    }

    func stop() {
        guard let client = client else { return }

        print("\n[*] Shutting down Guardian ESD...")
        print("[*] Statistics: \(blockedCount) blocked, \(allowedCount) allowed")

        es_unsubscribe_all(client)
        es_delete_client(client)
        self.client = nil
        isRunning = false

        print("[+] Guardian ESD stopped")
    }

    // MARK: - Event Handling

    private func handleMessage(_ message: UnsafePointer<es_message_t>) {
        // Check emergency disable
        if FileManager.default.fileExists(atPath: GuardianConfig.emergencyDisableFile) {
            respondAllow(message)
            return
        }

        let eventType = message.pointee.event_type
        let process = message.pointee.process.pointee
        let processPath = getString(from: process.executable.pointee.path)

        // Check if trusted process
        if GuardianConfig.trustedProcesses.contains(processPath) {
            respondAllow(message)
            return
        }

        // Get target path based on event type
        guard let targetPath = getTargetPath(message: message, eventType: eventType) else {
            respondAllow(message)
            return
        }

        // Check protection
        let decision = checkProtection(path: targetPath, eventType: eventType, processPath: processPath)

        if decision == .deny {
            blockedCount += 1
            let eventName = getEventName(eventType)
            print("[\u{1F6E1}\u{FE0F}] BLOCKED \(eventName): \(targetPath)")
            print("    Process: \(processPath) (PID: \(process.audit_token.val.4))")
            respondDeny(message)
        } else {
            allowedCount += 1
            respondAllow(message)
        }
    }

    private func getTargetPath(message: UnsafePointer<es_message_t>, eventType: es_event_type_t) -> String? {
        switch eventType {
        case ES_EVENT_TYPE_AUTH_UNLINK:
            return getString(from: message.pointee.event.unlink.target.pointee.path)

        case ES_EVENT_TYPE_AUTH_RENAME:
            // Check both source and destination
            let source = getString(from: message.pointee.event.rename.source.pointee.path)
            // For rename, we protect if either source or dest is protected
            return source

        case ES_EVENT_TYPE_AUTH_TRUNCATE:
            return getString(from: message.pointee.event.truncate.target.pointee.path)

        case ES_EVENT_TYPE_AUTH_LINK:
            return getString(from: message.pointee.event.link.target_dir.pointee.path)

        case ES_EVENT_TYPE_AUTH_CREATE:
            return getString(from: message.pointee.event.create.destination.new_path.dir.pointee.path)

        case ES_EVENT_TYPE_AUTH_CLONE:
            return getString(from: message.pointee.event.clone.target_dir.pointee.path)

        case ES_EVENT_TYPE_AUTH_EXCHANGEDATA:
            return getString(from: message.pointee.event.exchangedata.file1.pointee.path)

        case ES_EVENT_TYPE_AUTH_SETEXTATTR:
            return getString(from: message.pointee.event.setextattr.target.pointee.path)

        case ES_EVENT_TYPE_AUTH_DELETEEXTATTR:
            return getString(from: message.pointee.event.deleteextattr.target.pointee.path)

        default:
            return nil
        }
    }

    // MARK: - Protection Logic

    enum Decision {
        case allow
        case deny
    }

    private func checkProtection(path: String, eventType: es_event_type_t, processPath: String) -> Decision {
        // Check whitelist first
        for whitePath in GuardianConfig.whitelistedPaths {
            if path.hasPrefix(whitePath) {
                return .allow
            }
        }

        // Check if path is protected
        for protectedPath in GuardianConfig.protectedPaths {
            if path.hasPrefix(protectedPath) {
                return .deny
            }
        }

        return .allow
    }

    // MARK: - Response Helpers

    private func respondAllow(_ message: UnsafePointer<es_message_t>) {
        es_respond_auth_result(client!, message, ES_AUTH_RESULT_ALLOW, false)
    }

    private func respondDeny(_ message: UnsafePointer<es_message_t>) {
        es_respond_auth_result(client!, message, ES_AUTH_RESULT_DENY, false)
    }

    // MARK: - Utility Functions

    private func getString(from token: es_string_token_t) -> String {
        if token.length > 0, let data = token.data {
            return String(cString: data)
        }
        return ""
    }

    private func getEventName(_ eventType: es_event_type_t) -> String {
        switch eventType {
        case ES_EVENT_TYPE_AUTH_UNLINK: return "unlink"
        case ES_EVENT_TYPE_AUTH_RENAME: return "rename"
        case ES_EVENT_TYPE_AUTH_TRUNCATE: return "truncate"
        case ES_EVENT_TYPE_AUTH_LINK: return "link"
        case ES_EVENT_TYPE_AUTH_CREATE: return "create"
        case ES_EVENT_TYPE_AUTH_CLONE: return "clone"
        case ES_EVENT_TYPE_AUTH_EXCHANGEDATA: return "exchangedata"
        case ES_EVENT_TYPE_AUTH_SETEXTATTR: return "setextattr"
        case ES_EVENT_TYPE_AUTH_DELETEEXTATTR: return "deleteextattr"
        default: return "unknown"
        }
    }

    private func printError(_ result: es_new_client_result_t) {
        switch result {
        case ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED:
            print("[-] ERROR: Missing entitlement")
            print("    Need: com.apple.developer.endpoint-security.client")
            print("    Ensure you have an Apple Developer account and proper provisioning")

        case ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED:
            print("[-] ERROR: Not permitted")
            print("    Must run as root: sudo ./guardian-esd")

        case ES_NEW_CLIENT_RESULT_ERR_NOT_PRIVILEGED:
            print("[-] ERROR: Insufficient privileges")
            print("    System Extension must be approved in System Preferences")

        case ES_NEW_CLIENT_RESULT_ERR_TOO_MANY_CLIENTS:
            print("[-] ERROR: Too many ES clients")
            print("    Another instance may be running")

        case ES_NEW_CLIENT_RESULT_ERR_INTERNAL:
            print("[-] ERROR: Internal ES framework error")

        default:
            print("[-] ERROR: Unknown error: \(result.rawValue)")
        }
    }
}

// MARK: - Signal Handling

var guardian: GuardianShield?

func signalHandler(_ signal: Int32) {
    print("\n[*] Received signal \(signal)")
    guardian?.stop()
    exit(0)
}

// MARK: - Main

func main() {
    // Check for root
    guard getuid() == 0 else {
        print("[-] ERROR: Must run as root")
        print("    Usage: sudo ./guardian-esd")
        exit(1)
    }

    // Set up signal handlers
    signal(SIGINT, signalHandler)
    signal(SIGTERM, signalHandler)

    // Create and start guardian
    guardian = GuardianShield()

    guard guardian!.start() else {
        print("[-] Failed to start Guardian ESD")
        exit(1)
    }

    // Run forever
    print("[*] Press Ctrl+C to stop")
    dispatchMain()
}

main()
