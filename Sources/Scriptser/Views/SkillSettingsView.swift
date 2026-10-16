import AppKit
import SwiftUI

struct SkillSettingsView: View {
    @EnvironmentObject private var store: ScriptStore
    @Environment(\.dismiss) private var dismiss
    @State private var generatedURL: URL?
    @State private var preview = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.text("AI Skill"), systemImage: "sparkles").font(.title2.weight(.semibold))
            Text(L10n.text("Generate a Skill for code-based Scriptser control, including while the screen is locked."))
                .foregroundStyle(.secondary)
            GroupBox(L10n.text("Skill Directory")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(store.settings.skillDirectory).font(.system(.body, design: .monospaced))
                            .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        Spacer()
                        Button(L10n.text("Choose Directory...")) { chooseDirectory() }
                    }
                    Text(L10n.format("Creates %@ with instructions, API reference, and a Python client.", store.skillManager.skillName))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("Generating again updates the bundled instructions. Additional files are preserved."))
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox(L10n.text("Add to Your AI Assistant")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("1. Choose your assistant’s skills directory. Codex defaults to ~/.codex/skills (or $CODEX_HOME/skills)."))
                    Text(L10n.text("2. Click Generate Skill. For another assistant, choose its skills directory or import the generated folder."))
                    Text(L10n.format("3. Start a new chat and invoke $%@, or copy the prompt below to load this Skill by path.", store.skillManager.skillName))
                    Text(L10n.text("Requires Python 3 and Scriptser running in your logged-in session. No UI automation or Accessibility permission is needed."))
                        .font(.caption).foregroundStyle(.secondary)
                    if let generatedURL {
                        Label(L10n.format("Generated at %@", generatedURL.path), systemImage: "checkmark.circle")
                            .font(.caption).textSelection(.enabled)
                        HStack {
                            Button(L10n.text(copied ? "Prompt Copied" : "Copy Adding Prompt")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(store.skillManager.installationPrompt(in: store.settings.skillDirectory), forType: .string)
                                copied = true
                            }
                            Button(L10n.text("Open Skill Folder")) { NSWorkspace.shared.open(generatedURL) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            DisclosureGroup(L10n.text("Preview Skill")) {
                ScrollView {
                    Text(preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 140)
            }
            HStack {
                Spacer()
                Button(L10n.text("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("Generate Skill")) {
                    do {
                        generatedURL = try store.skillManager.generate(in: store.settings.skillDirectory)
                        copied = false
                    } catch let error as SkillError { store.lastError = .skillError(error) }
                    catch { store.lastError = .skillError(.generationFailed(error)) }
                }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(20).frame(width: 660)
        .task {
            do { preview = try store.skillManager.preview() }
            catch let error as SkillError { store.lastError = .skillError(error) }
            catch { store.lastError = .skillError(.generationFailed(error)) }
        }
        .errorAlert($store.lastError)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: store.settings.skillDirectory)
        panel.message = L10n.text("Select the parent directory where your assistant discovers Skills.")
        panel.prompt = L10n.text("Select")
        if panel.runModal() == .OK, let url = panel.url {
            store.settings.skillDirectory = url.path
            generatedURL = nil
            copied = false
        }
    }
}
