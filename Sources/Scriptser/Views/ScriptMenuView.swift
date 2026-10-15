import AppKit
import SwiftUI

/// A compact, scrollable menu for quick script access.
struct ScriptMenuView: View {
    @EnvironmentObject private var store: ScriptStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismissMenu
    @State private var expandedScriptIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Scriptser", systemImage: "terminal").font(.headline)
                Spacer()
                Button(L10n.text("Manager")) {
                    showManager()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            HStack(spacing: 8) {
                Button { store.runAll() } label: { Label(L10n.text("Run All"), systemImage: "play.fill") }
                    .disabled(!store.isReady || !store.scripts.contains { $0.isEnabled && !store.isRunning($0) })
                Button { store.stopAll() } label: { Label(L10n.text("Stop All"), systemImage: "stop.fill") }
                    .disabled(!store.scripts.contains { store.isRunning($0) })
                Spacer()
            }
            Divider()
            Text(L10n.format("%d scripts · %d running", store.scripts.count, store.scripts.filter { store.isRunning($0) }.count))
                .font(.caption).foregroundStyle(.secondary)
            if store.scripts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("No scripts yet")).font(.headline)
                    Text(L10n.text("Add scripts in Manager to get started."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(store.scripts) { script in
                            ScriptRowView(
                                script: script,
                                isExpanded: Binding(
                                    get: { expandedScriptIDs.contains(script.id) },
                                    set: { if $0 { expandedScriptIDs.insert(script.id) } else { expandedScriptIDs.remove(script.id) } }
                                ),
                                onEdit: { store.editingScript = script; showManager() }
                            )
                        }
                    }
                }
                // A finite height keeps the menu's scroll view from collapsing in MenuBarExtra.
                .frame(height: min(CGFloat(store.scripts.count) * 64
                                   + CGFloat(store.scripts.filter { expandedScriptIDs.contains($0.id) }.count) * 280, 420))
            }
            Button { store.editingScript = .empty(); showManager() } label: {
                Label(L10n.text("Add Custom Command..."), systemImage: "plus")
            }
            Divider()
            UpdateControlsView()
            HStack {
                Text(L10n.format("%d running", store.scripts.filter { store.isRunning($0) }.count))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("Quit")) { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(16)
        .frame(width: 420)
        .errorAlert($store.lastError)
    }

    private func showManager() {
        // Dismiss the menu bar popover before opening the Manager window.
        dismissMenu()
        if let keyWindow = NSApp.keyWindow {
            keyWindow.performClose(nil)
        }
        openWindow(id: ScriptserApp.managerWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
