import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status header
            HStack {
                Circle()
                    .fill(appState.isProtectionActive ? .green : .red)
                    .frame(width: 8, height: 8)

                Text(appState.isProtectionActive ? "Protection Active" : "Protection Disabled")
                    .font(.headline)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial)

            Divider()

            // Quick actions
            VStack(spacing: 0) {
                // Toggle
                Button {
                    appState.toggleProtection()
                } label: {
                    HStack {
                        Image(systemName: appState.isProtectionActive ? "pause.circle" : "play.circle")
                        Text(appState.isProtectionActive ? "Disable Protection" : "Enable Protection")
                        Spacer()
                    }
                }
                .buttonStyle(MenuItemButtonStyle())

                // Temporary disable submenu
                if appState.isProtectionActive {
                    Menu {
                        Button("5 minutes") { appState.temporaryDisable(minutes: 5) }
                        Button("15 minutes") { appState.temporaryDisable(minutes: 15) }
                        Button("1 hour") { appState.temporaryDisable(minutes: 60) }
                    } label: {
                        HStack {
                            Image(systemName: "clock")
                            Text("Disable Temporarily")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(MenuItemButtonStyle())
                }
            }

            Divider()
                .padding(.vertical, 4)

            // Recent blocks
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent Blocks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)

                if appState.recentBlocks.isEmpty {
                    Text("No recent blocks")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                } else {
                    ForEach(appState.recentBlocks.prefix(5)) { event in
                        MenuBlockRow(event: event)
                    }
                }
            }
            .padding(.vertical, 4)

            Divider()
                .padding(.vertical, 4)

            // Open main window
            Button {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.title.isEmpty || $0.title == "Guardian Shield" }) {
                    window.makeKeyAndOrderFront(nil)
                }
            } label: {
                HStack {
                    Image(systemName: "macwindow")
                    Text("Open Guardian Shield")
                    Spacer()
                    Text("G")
                        .font(.caption)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                }
            }
            .buttonStyle(MenuItemButtonStyle())
            .keyboardShortcut("g", modifiers: .command)

            Divider()
                .padding(.vertical, 4)

            // Quit
            Button {
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Quit Guardian Shield")
                    Spacer()
                    Text("Q")
                        .font(.caption)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                }
            }
            .buttonStyle(MenuItemButtonStyle())
            .keyboardShortcut("q", modifiers: .command)
        }
        .frame(width: 280)
    }
}

struct MenuBlockRow: View {
    let event: BlockEvent

    var severityColor: Color {
        switch event.severity {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .green
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(severityColor)
                .frame(width: 6, height: 6)

            Text(event.operation)
                .font(.caption)
                .fontWeight(.medium)

            Text(event.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

struct MenuItemButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(configuration.isPressed ? Color.primary.opacity(0.1) : .clear)
            .contentShape(Rectangle())
    }
}

#Preview {
    MenuBarView()
        .environmentObject({
            let state = AppState()
            state.recentBlocks = [
                BlockEvent(operation: "unlink", path: "/etc/passwd", severity: .critical),
                BlockEvent(operation: "rename", path: "~/.git/config", severity: .high),
            ]
            return state
        }())
}
