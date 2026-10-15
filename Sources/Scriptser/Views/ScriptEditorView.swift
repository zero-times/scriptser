import AppKit
import SwiftUI

/// Dialog for creating or editing any shell command.
struct ScriptEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ScriptStore
    @State private var draft: ScriptEntry
    @FocusState private var nameFocused: Bool
    private let isNew: Bool
    let onSave: (ScriptEntry) -> Void

    init(script: ScriptEntry, onSave: @escaping (ScriptEntry) -> Void) {
        _draft = State(initialValue: script)
        isNew = script.name.isEmpty && script.command.isEmpty
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(L10n.text(isNew ? "New Script" : "Edit Script"), systemImage: "terminal")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Name")).font(.headline)
                TextField(L10n.text("Script name"), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Notes (optional)")).font(.headline)
                TextField(L10n.text("Describe what this script does"), text: $draft.notes, axis: .vertical)
                    .lineLimit(2...3)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.text("Notes (optional)"))
                Text(L10n.text("Shown in the script list. Commands and process details stay in Details."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Command")).font(.headline)
                TextEditor(text: $draft.command)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120, maxHeight: 220)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    .accessibilityLabel(L10n.text("Command"))
                Text(L10n.text("Enter any shell command or a multiline script. Runs in zsh using your shell environment."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Working Directory (optional)")).font(.headline)
                HStack {
                    TextField(L10n.text("Leave empty to use the default directory"), text: $draft.workingDirectory)
                        .textFieldStyle(.roundedBorder)
                    Button(L10n.text("Browse...")) { browseDirectory() }
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(L10n.text("Enabled"), isOn: $draft.isEnabled)
                    Toggle(L10n.text("Run when Scriptser launches"), isOn: $draft.runAtLaunch)
                    Text(L10n.text("Only enabled scripts run at launch. Scripts already running are restored without starting again."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            HStack {
                Spacer()
                Button(L10n.text("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("Save")) { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 580)
        .onAppear { nameFocused = true }
    }

    private func save() {
        var cleaned = draft
        cleaned.name = cleaned.name.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.notes = cleaned.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.command = cleaned.command.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.workingDirectory = cleaned.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(cleaned)
        dismiss()
    }

    private func browseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.text("Select working directory")
        panel.prompt = L10n.text("Select")
        if panel.runModal() == .OK, let url = panel.url {
            draft.workingDirectory = url.path
        }
    }
}
