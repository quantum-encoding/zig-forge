import SwiftUI

struct RecentBlocksCard: View {
    @EnvironmentObject var appState: AppState
    @State private var filterText = ""
    @State private var selectedSeverity: BlockEvent.Severity? = nil

    var filteredBlocks: [BlockEvent] {
        appState.recentBlocks.filter { event in
            let matchesText = filterText.isEmpty ||
                event.path.localizedCaseInsensitiveContains(filterText) ||
                event.operation.localizedCaseInsensitiveContains(filterText)

            let matchesSeverity = selectedSeverity == nil || event.severity == selectedSeverity

            return matchesText && matchesSeverity
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Label("Recent Blocks", systemImage: "shield.lefthalf.filled.slash")
                    .font(.headline)

                Spacer()

                // Severity filter
                Picker("Severity", selection: $selectedSeverity) {
                    Text("All").tag(nil as BlockEvent.Severity?)
                    Text("Critical").tag(BlockEvent.Severity.critical as BlockEvent.Severity?)
                    Text("High").tag(BlockEvent.Severity.high as BlockEvent.Severity?)
                    Text("Medium").tag(BlockEvent.Severity.medium as BlockEvent.Severity?)
                    Text("Low").tag(BlockEvent.Severity.low as BlockEvent.Severity?)
                }
                .pickerStyle(.menu)
                .frame(width: 100)
            }

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter by path or operation...", text: $filterText)
                    .textFieldStyle(.plain)

                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            // Block list
            if filteredBlocks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield")
                        .font(.largeTitle)
                        .foregroundStyle(.green)
                    Text("No blocks recorded")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredBlocks.prefix(50)) { event in
                            BlockEventRow(event: event)
                        }
                    }
                }
                .frame(maxHeight: 250)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct BlockEventRow: View {
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
        HStack(spacing: 12) {
            // Severity indicator
            Circle()
                .fill(severityColor)
                .frame(width: 8, height: 8)

            // Operation badge
            Text(event.operation.uppercased())
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))

            // Path
            Text(event.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Timestamp
            Text(event.timestamp, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    RecentBlocksCard()
        .environmentObject({
            let state = AppState()
            state.recentBlocks = [
                BlockEvent(operation: "unlink", path: "/etc/passwd", severity: .critical),
                BlockEvent(operation: "rename", path: "/Users/test/.git/config", severity: .high),
                BlockEvent(operation: "rmdir", path: "/tmp/test", severity: .low),
            ]
            return state
        }())
        .padding()
        .frame(width: 500)
}
