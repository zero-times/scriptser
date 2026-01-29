import SwiftUI
import UniformTypeIdentifiers

/// Main script management window
struct ScriptManagerView: View {
    @EnvironmentObject private var store: ScriptStore
    @State private var editingScript: ScriptEntry?
    @State private var viewingOutputScript: ScriptEntry?
    @State private var scriptToDelete: ScriptEntry?
    @State private var showingDeleteConfirmation = false
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var selectedScriptId: UUID?

    var body: some View {
        VStack(spacing: 12) {
            // Header with search
            headerView

            // Script list
            scriptListView

            // Footer controls
            footerView

            // Settings
            settingsView
        }
        .padding(16)
        .frame(minWidth: 800, minHeight: 520)
        .sheet(item: $editingScript) { script in
            ScriptEditorView(script: script) { updated in
                store.upsert(updated)
            }
        }
        .sheet(item: $viewingOutputScript) { script in
            OutputViewerView(script: script)
        }
        .confirmationDialog(
            "Delete Script",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let script = scriptToDelete {
                    store.remove(script)
                }
                scriptToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                scriptToDelete = nil
            }
        } message: {
            Text("Are you sure you want to delete \"\(scriptToDelete?.name ?? "Unknown")\"? This action cannot be undone.")
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.importScripts(from: url)
            }
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: ScriptsDocument(scripts: store.scripts),
            contentType: .json,
            defaultFilename: "scripts-export"
        ) { _ in }
        .errorAlert($store.lastError)
    }

    private var headerView: some View {
        HStack {
            Text("Scripts")
                .font(.title2)

            Spacer()

            // Search field
            TextField("Search scripts...", text: $store.searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            Button {
                editingScript = ScriptEntry.empty()
            } label: {
                Label("Add Script", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    private var scriptListView: some View {
        List(selection: $selectedScriptId) {
            ForEach(store.filteredScripts) { script in
                ScriptManagerRow(
                    script: script,
                    onEdit: { editingScript = script },
                    onViewOutput: { viewingOutputScript = script },
                    onDelete: {
                        scriptToDelete = script
                        showingDeleteConfirmation = true
                    }
                )
                .tag(script.id)
            }
            .onDelete { offsets in
                let scriptsToDelete = offsets.map { store.filteredScripts[$0] }
                if let first = scriptsToDelete.first {
                    scriptToDelete = first
                    showingDeleteConfirmation = true
                }
            }
        }
    }

    private var footerView: some View {
        HStack {
            Button("Run All") {
                store.runAll()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button("Stop All") {
                store.stopAll()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])

            Spacer()

            Menu("Import/Export") {
                Button("Import Scripts...") {
                    showingImporter = true
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("Export Scripts...") {
                    showingExporter = true
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }

            Button("Open Config Folder") {
                store.openConfigFolder()
            }
        }
    }

    private var settingsView: some View {
        HStack {
            Toggle("Launch at Login", isOn: Binding(
                get: { store.settings.launchAtLoginEnabled },
                set: { store.settings.launchAtLoginEnabled = $0 }
            ))

            Spacer()
        }
    }
}

/// Single row in the script manager list
struct ScriptManagerRow: View {
    @EnvironmentObject private var store: ScriptStore
    let script: ScriptEntry
    let onEdit: () -> Void
    let onViewOutput: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let state = store.status(for: script)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StatusBadge(status: state.status)

                Text(script.name.isEmpty ? "Untitled Script" : script.name)
                    .font(.headline)

                if !script.isEnabled {
                    Text("Disabled")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }

                Spacer()

                actionButtons(state: state)
            }

            // Details
            Text("Command: \(script.command)")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            HStack {
                if !script.workingDirectory.isEmpty {
                    Text("Dir: \(script.workingDirectory)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if let startedAt = state.startedAt {
                    Text("Last: \(RelativeDateTimeFormatter().localizedString(for: startedAt, relativeTo: Date()))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if let duration = state.formattedDuration {
                    Text("(\(duration))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func actionButtons(state: ScriptRunState) -> some View {
        HStack(spacing: 4) {
            Button("Edit") {
                onEdit()
            }

            Button("Output") {
                onViewOutput()
            }

            if store.isRunning(script) {
                Button("Stop") {
                    store.stop(script)
                }
            } else {
                Button("Run") {
                    store.run(script)
                }
                .disabled(!script.isEnabled)
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)

            // Quick actions menu
            if let template = matchingQuickActionTemplate {
                Menu {
                    ForEach(template.actions) { action in
                        Button(action.label) {
                            runQuickAction(action, template: template)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var matchingQuickActionTemplate: QuickActionTemplate? {
        store.settings.quickActionTemplates.first { template in
            script.command.contains(template.commandPattern)
        }
    }

    private func runQuickAction(_ action: QuickActionTemplate.QuickAction, template: QuickActionTemplate) {
        // Extract base command and replace with subcommand
        let baseCommand = script.command.replacingOccurrences(
            of: #"(\./[\w_]+\.sh)\s*\w*"#,
            with: "$1 \(action.subcommand)",
            options: .regularExpression
        )

        let proxy = ScriptEntry(
            id: UUID(), // Use new ID to not interfere with original script state
            name: "\(script.name) - \(action.label)",
            command: baseCommand,
            workingDirectory: script.workingDirectory,
            isEnabled: script.isEnabled
        )
        store.run(proxy)
    }
}

// MARK: - Error Alert Modifier

struct ErrorAlertModifier: ViewModifier {
    @Binding var error: ScriptStoreError?

    func body(content: Content) -> some View {
        content
            .alert(
                "Error",
                isPresented: Binding(
                    get: { error != nil },
                    set: { if !$0 { error = nil } }
                ),
                presenting: error
            ) { _ in
                Button("OK", role: .cancel) {
                    error = nil
                }
            } message: { error in
                Text(error.localizedDescription)
            }
    }
}

extension View {
    func errorAlert(_ error: Binding<ScriptStoreError?>) -> some View {
        modifier(ErrorAlertModifier(error: error))
    }
}
