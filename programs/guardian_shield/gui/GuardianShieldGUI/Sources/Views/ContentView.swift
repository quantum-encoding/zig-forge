import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .windowBackgroundColor).opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HeaderView()
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                Divider()
                    .padding(.horizontal, 20)

                // Content
                ScrollView {
                    VStack(spacing: 16) {
                        StatusCard()
                        RecentBlocksCard()
                        ProtectedPathsCard()
                        WhitelistCard()
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 550, minHeight: 600)
    }
}

// MARK: - Header
struct HeaderView: View {
    var body: some View {
        HStack {
            Image(systemName: "shield.checkered")
                .font(.system(size: 28))
                .foregroundStyle(.blue, .primary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Guardian Shield")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("System Protection Active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                NSApp.orderFrontStandardAboutPanel()
            } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Status Card
struct StatusCard: View {
    @EnvironmentObject var appState: AppState
    @State private var showingDisableOptions = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                // Status indicator
                HStack(spacing: 8) {
                    Circle()
                        .fill(appState.isProtectionActive ? .green : .red)
                        .frame(width: 10, height: 10)
                        .shadow(color: appState.isProtectionActive ? .green.opacity(0.5) : .red.opacity(0.5), radius: 4)

                    Text(appState.isProtectionActive ? "Protection Active" : "Protection Disabled")
                        .font(.headline)
                }

                Spacer()

                // Toggle / Disable button
                if appState.isProtectionActive {
                    Button("Disable") {
                        showingDisableOptions = true
                    }
                    .buttonStyle(.bordered)
                    .popover(isPresented: $showingDisableOptions) {
                        DisableOptionsView()
                            .environmentObject(appState)
                    }
                } else {
                    Button("Enable") {
                        appState.enableProtection()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }

            // Temporary disable info
            if let until = appState.temporaryDisableUntil {
                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(.orange)
                    Text("Re-enables at \(until.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Cancel") {
                        appState.enableProtection()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }

            // Stats row
            HStack(spacing: 24) {
                StatItem(value: "\(appState.recentBlocks.count)", label: "Blocks Today")
                StatItem(value: "\(appState.protectedPaths.count)", label: "Protected Paths")
                StatItem(value: "\(appState.whitelistedPaths.count)", label: "Whitelisted")
            }
            .padding(.top, 8)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct StatItem: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct DisableOptionsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Temporarily Disable")
                .font(.headline)

            Button("5 minutes") {
                appState.temporaryDisable(minutes: 5)
                dismiss()
            }
            .buttonStyle(.bordered)

            Button("15 minutes") {
                appState.temporaryDisable(minutes: 15)
                dismiss()
            }
            .buttonStyle(.bordered)

            Button("1 hour") {
                appState.temporaryDisable(minutes: 60)
                dismiss()
            }
            .buttonStyle(.bordered)

            Divider()

            Button("Disable Indefinitely") {
                appState.toggleProtection()
                dismiss()
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
        .padding()
        .frame(width: 180)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
