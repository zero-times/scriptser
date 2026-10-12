import AppKit
import SwiftUI

/// A compact, scrollable menu for quick script access.
struct ScriptMenuView: View {
    @EnvironmentObject private var store: ScriptStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Scriptser", systemImage: "terminal").font(.headline)
                Spacer()
                if #available(macOS 14.0, *) {
                    SettingsLink { Text(L10n.text("Manager")) }
                        .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
                        .keyboardShortcut(",", modifiers: .command)
                } else {
                    Button(L10n.text("Manager")) {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
            HStack(spacing: 8) {
                Button { store.runAll() } label: { Label(L10n.text("Run All"), systemImage: "play.fill") }
                    .disabled(!store.isReady || !store.scripts.contains { $0.isEnabled && !store.isRunning($0) })
                Button { store.stopAll() } label: { Label(L10n.text("Stop All"), systemImage: "stop.fill") }
                    .disabled(!store.scripts.contains { store.isRunning($0) })
                Spacer()
            }
            Divider()
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
                        ForEach(store.scripts) { ScriptMenuRow(script: $0) }
                    }
                }
                .frame(maxHeight: 320)
            }
            Divider()
            HStack {
                Text(L10n.format("%d running", store.scripts.filter { store.isRunning($0) }.count))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("Quit")) { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(16)
        .frame(width: 380)
        .errorAlert($store.lastError)
    }
}

struct ScriptMenuRow: View {
    @EnvironmentObject private var store: ScriptStore
    let script: ScriptEntry

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(script.name.isEmpty ? L10n.text("Untitled Script") : script.name)
                    .font(.body.weight(.medium)).lineLimit(1)
                    .foregroundStyle(script.isEnabled ? .primary : .secondary)
                HStack(spacing: 8) {
                    StatusBadge(status: store.status(for: script).status)
                    if !script.isEnabled { Text(L10n.text("Disabled")).foregroundStyle(.secondary) }
                    if script.runAtLaunch {
                        Image(systemName: "power").help(L10n.text("Run when Scriptser launches"))
                            .accessibilityLabel(L10n.text("Run when Scriptser launches"))
                    }
                }
                .font(.caption)
            }
            Spacer()
            if store.isRunning(script) {
                Button(L10n.text("Stop")) { store.stop(script) }
            } else {
                Button(L10n.text("Run")) { store.run(script) }
                    .disabled(!script.isEnabled || !store.isReady)
            }
        }
    }
}
