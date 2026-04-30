import SwiftUI

@main
struct GuardianShieldApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        // Menu Bar Extra
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.isProtectionActive ? "shield.checkered" : "shield.slash")
                .symbolRenderingMode(.palette)
                .foregroundStyle(appState.isProtectionActive ? .green : .red, .primary)
        }
        .menuBarExtraStyle(.window)

        // Main Window
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 600, height: 700)
    }
}

// MARK: - App State
@MainActor
class AppState: ObservableObject {
    @Published var isProtectionActive: Bool = true
    @Published var recentBlocks: [BlockEvent] = []
    @Published var protectedPaths: [ProtectedPath] = []
    @Published var whitelistedPaths: [String] = []
    @Published var temporaryDisableUntil: Date? = nil

    private var eventMonitor: EventMonitor?
    private var configService: ConfigService?

    init() {
        configService = ConfigService()
        eventMonitor = EventMonitor { [weak self] event in
            Task { @MainActor in
                self?.recentBlocks.insert(event, at: 0)
                if (self?.recentBlocks.count ?? 0) > 100 {
                    self?.recentBlocks.removeLast()
                }
            }
        }

        loadConfig()
        checkProtectionStatus()
        eventMonitor?.startMonitoring()
    }

    func loadConfig() {
        if let config = configService?.loadConfig() {
            protectedPaths = config.protectedPaths
            whitelistedPaths = config.whitelistedPaths
            isProtectionActive = config.enabled
        }
    }

    func checkProtectionStatus() {
        // Check if emergency disable file exists
        let emergencyFile = "/tmp/.warden_emergency_disable"
        isProtectionActive = !FileManager.default.fileExists(atPath: emergencyFile)

        // Check temporary disable
        if let until = temporaryDisableUntil, Date() < until {
            isProtectionActive = false
        }
    }

    func toggleProtection() {
        let emergencyFile = "/tmp/.warden_emergency_disable"
        if isProtectionActive {
            // Disable - create magic file
            FileManager.default.createFile(atPath: emergencyFile, contents: nil)
        } else {
            // Enable - remove magic file
            try? FileManager.default.removeItem(atPath: emergencyFile)
        }
        isProtectionActive.toggle()
    }

    func temporaryDisable(minutes: Int) {
        temporaryDisableUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        let emergencyFile = "/tmp/.warden_emergency_disable"
        FileManager.default.createFile(atPath: emergencyFile, contents: nil)
        isProtectionActive = false

        // Schedule re-enable
        DispatchQueue.main.asyncAfter(deadline: .now() + .minutes(minutes)) { [weak self] in
            self?.enableProtection()
        }
    }

    func enableProtection() {
        temporaryDisableUntil = nil
        let emergencyFile = "/tmp/.warden_emergency_disable"
        try? FileManager.default.removeItem(atPath: emergencyFile)
        isProtectionActive = true
    }
}

extension DispatchTimeInterval {
    static func minutes(_ n: Int) -> DispatchTimeInterval {
        .seconds(n * 60)
    }
}
