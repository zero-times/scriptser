import SwiftUI

/// Dialog for creating or editing a script
struct ScriptEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ScriptStore
    @State private var draft: ScriptEntry
    let onSave: (ScriptEntry) -> Void

    init(script: ScriptEntry, onSave: @escaping (ScriptEntry) -> Void) {
        _draft = State(initialValue: script)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.name.isEmpty ? "New Script" : "Edit Script")
                .font(.title2)

            Form {
                TextField("Name", text: $draft.name)
                TextField("Command", text: $draft.command)
                HStack {
                    TextField("Working Directory (optional)", text: $draft.workingDirectory)
                    Button("Browse...") {
                        browseDirectory()
                    }
                }
                Toggle("Enabled", isOn: $draft.isEnabled)
            }

            GroupBox("Quick Commands") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(store.settings.quickActionTemplates) { template in
                            ForEach(template.actions) { action in
                                Button(action.label) {
                                    applyQuickCommand(
                                        name: "\(template.name) \(action.label)",
                                        command: "./\(template.commandPattern.components(separatedBy: "/").last ?? template.commandPattern) \(action.subcommand)"
                                    )
                                }
                            }
                        }
                    }
                    Text("Quick commands will set the command and working directory if empty.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Button("Save") {
                    var cleaned = draft
                    cleaned.name = cleaned.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    cleaned.command = cleaned.command.trimmingCharacters(in: .whitespacesAndNewlines)
                    cleaned.workingDirectory = cleaned.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(cleaned)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 560)
    }

    private func applyQuickCommand(name: String, command: String) {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.name = name
        }
        draft.command = command

        if draft.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.workingDirectory = store.settings.dockerDirectory
        }
    }

    private func browseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select working directory"

        if panel.runModal() == .OK, let url = panel.url {
            draft.workingDirectory = url.path
        }
    }
}
