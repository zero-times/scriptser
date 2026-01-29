import AppKit
import SwiftUI

/// Menu bar dropdown view for quick script access
struct ScriptMenuView: View {
    @EnvironmentObject private var store: ScriptStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scriptser")
                    .font(.headline)
                Spacer()
                if #available(macOS 14.0, *) {
                    SettingsLink {
                        Text("Manager")
                    }
                } else {
                    Button("Manager") {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Run All") {
                    store.runAll()
                }
                Button("Stop All") {
                    store.stopAll()
                }
            }

            Divider()

            if store.scripts.isEmpty {
                Text("No scripts configured.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(store.scripts) { script in
                    ScriptMenuRow(script: script)
                }
            }

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 360)
    }
}

/// Single row in the menu bar dropdown
struct ScriptMenuRow: View {
    @EnvironmentObject private var store: ScriptStore
    let script: ScriptEntry

    var body: some View {
        let state = store.status(for: script)

        HStack {
            StatusBadge(status: state.status)
            Text(script.name.isEmpty ? "Untitled Script" : script.name)
                .lineLimit(1)
            Spacer()
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
        }
        .font(.caption)
    }
}
