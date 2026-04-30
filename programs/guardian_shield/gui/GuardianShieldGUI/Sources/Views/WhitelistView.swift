import SwiftUI

struct WhitelistCard: View {
    @EnvironmentObject var appState: AppState
    @State private var newPath = ""
    @State private var showingAddField = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Label("Whitelisted Paths", systemImage: "checkmark.circle")
                    .font(.headline)

                Spacer()

                Button {
                    showingAddField = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
            }

            // Add field
            if showingAddField {
                HStack {
                    TextField("Enter path to whitelist...", text: $newPath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            addPath()
                        }

                    Button("Add") {
                        addPath()
                    }
                    .disabled(newPath.isEmpty)

                    Button {
                        showingAddField = false
                        newPath = ""
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
            }

            // Path list
            if appState.whitelistedPaths.isEmpty && !showingAddField {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.green.opacity(0.5))
                    Text("No whitelisted paths")
                        .foregroundStyle(.secondary)
                    Text("Whitelisted paths bypass protection")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach(appState.whitelistedPaths, id: \.self) { path in
                    WhitelistPathRow(path: path) {
                        appState.whitelistedPaths.removeAll { $0 == path }
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func addPath() {
        guard !newPath.isEmpty else { return }
        appState.whitelistedPaths.append(newPath)
        newPath = ""
        showingAddField = false
    }
}

struct WhitelistPathRow: View {
    let path: String
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            Text(path)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)

            Spacer()

            if isHovered {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(isHovered ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { isHovered = $0 }
    }
}

#Preview {
    WhitelistCard()
        .environmentObject({
            let state = AppState()
            state.whitelistedPaths = [
                "/tmp/build-output",
                "/Users/test/scratch"
            ]
            return state
        }())
        .padding()
        .frame(width: 500)
}
