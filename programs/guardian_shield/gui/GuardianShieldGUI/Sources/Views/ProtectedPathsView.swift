import SwiftUI

struct ProtectedPathsCard: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAddSheet = false
    @State private var editingPath: ProtectedPath? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Label("Protected Paths", systemImage: "folder.badge.gearshape")
                    .font(.headline)

                Spacer()

                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }

            // Path list
            if appState.protectedPaths.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No paths protected")
                        .foregroundStyle(.secondary)
                    Text("Add paths to protect them from modification")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach(appState.protectedPaths) { path in
                    ProtectedPathRow(
                        path: path,
                        onEdit: { editingPath = path },
                        onDelete: { removePath(path) }
                    )
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $showingAddSheet) {
            AddPathSheet(isPresented: $showingAddSheet) { newPath in
                appState.protectedPaths.append(newPath)
            }
        }
        .sheet(item: $editingPath) { path in
            EditPathSheet(path: path, isPresented: .init(
                get: { editingPath != nil },
                set: { if !$0 { editingPath = nil } }
            )) { updatedPath in
                if let index = appState.protectedPaths.firstIndex(where: { $0.id == updatedPath.id }) {
                    appState.protectedPaths[index] = updatedPath
                }
            }
        }
    }

    private func removePath(_ path: ProtectedPath) {
        appState.protectedPaths.removeAll { $0.id == path.id }
    }
}

struct ProtectedPathRow: View {
    let path: ProtectedPath
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(path.path)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)

                if !path.description.isEmpty {
                    Text(path.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Operations
                HStack(spacing: 4) {
                    ForEach(path.blockOperations.prefix(3), id: \.self) { op in
                        Text(op)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    }
                    if path.blockOperations.count > 3 {
                        Text("+\(path.blockOperations.count - 3)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if isHovered {
                HStack(spacing: 8) {
                    Button {
                        onEdit()
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)

                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(isHovered ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { isHovered = $0 }
    }
}

struct AddPathSheet: View {
    @Binding var isPresented: Bool
    let onAdd: (ProtectedPath) -> Void

    @State private var path = ""
    @State private var description = ""
    @State private var selectedOperations: Set<String> = ["unlink", "rmdir", "rename"]

    let availableOperations = ["unlink", "rmdir", "rename", "open_write", "chmod", "truncate", "symlink"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Protected Path")
                .font(.title2)
                .fontWeight(.semibold)

            // Path input
            VStack(alignment: .leading, spacing: 4) {
                Text("Path")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("/path/to/protect", text: $path)
                        .textFieldStyle(.roundedBorder)

                    Button("Browse...") {
                        browsePath()
                    }
                }
            }

            // Description
            VStack(alignment: .leading, spacing: 4) {
                Text("Description (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("e.g., Git repository", text: $description)
                    .textFieldStyle(.roundedBorder)
            }

            // Operations
            VStack(alignment: .leading, spacing: 8) {
                Text("Block Operations")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
                    ForEach(availableOperations, id: \.self) { op in
                        Toggle(op, isOn: Binding(
                            get: { selectedOperations.contains(op) },
                            set: { if $0 { selectedOperations.insert(op) } else { selectedOperations.remove(op) } }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }

            Spacer()

            // Actions
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    let newPath = ProtectedPath(
                        path: path,
                        description: description,
                        blockOperations: Array(selectedOperations)
                    )
                    onAdd(newPath)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(path.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400, height: 350)
    }

    private func browsePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}

struct EditPathSheet: View {
    let path: ProtectedPath
    @Binding var isPresented: Bool
    let onSave: (ProtectedPath) -> Void

    @State private var editedPath: String
    @State private var editedDescription: String
    @State private var selectedOperations: Set<String>

    let availableOperations = ["unlink", "rmdir", "rename", "open_write", "chmod", "truncate", "symlink"]

    init(path: ProtectedPath, isPresented: Binding<Bool>, onSave: @escaping (ProtectedPath) -> Void) {
        self.path = path
        self._isPresented = isPresented
        self.onSave = onSave
        self._editedPath = State(initialValue: path.path)
        self._editedDescription = State(initialValue: path.description)
        self._selectedOperations = State(initialValue: Set(path.blockOperations))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Protected Path")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 4) {
                Text("Path")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("/path/to/protect", text: $editedPath)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Description")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Description", text: $editedDescription)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Block Operations")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
                    ForEach(availableOperations, id: \.self) { op in
                        Toggle(op, isOn: Binding(
                            get: { selectedOperations.contains(op) },
                            set: { if $0 { selectedOperations.insert(op) } else { selectedOperations.remove(op) } }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }

            Spacer()

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    let updated = ProtectedPath(
                        id: path.id,
                        path: editedPath,
                        description: editedDescription,
                        blockOperations: Array(selectedOperations)
                    )
                    onSave(updated)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400, height: 350)
    }
}

#Preview {
    ProtectedPathsCard()
        .environmentObject({
            let state = AppState()
            state.protectedPaths = [
                ProtectedPath(path: "/etc/", description: "System config", blockOperations: ["unlink", "rmdir"]),
                ProtectedPath(path: "/Users/test/.git", description: "Git repo", blockOperations: ["unlink", "rename", "rmdir"]),
            ]
            return state
        }())
        .padding()
        .frame(width: 500)
}
