import SwiftUI

/// Shared PID display and force-termination action for every running-script surface.
struct ProcessDetailsView: View {
    @EnvironmentObject private var store: ScriptStore
    let script: ScriptEntry
    @State private var confirming = false
    @State private var selectedPID: Int32?

    var body: some View {
        if store.isRunning(script), let pid = store.status(for: script).pid {
            HStack(spacing: 8) {
                Text(L10n.format("PID: %@", String(pid)))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button(L10n.text("End Process"), role: .destructive) {
                    selectedPID = pid
                    confirming = true
                }
                .font(.caption).buttonStyle(.borderless)
                .help(L10n.text("Force end the tracked process using SIGKILL."))
            }
            .confirmationDialog(L10n.text("End Process"), isPresented: $confirming, titleVisibility: .visible) {
                Button(L10n.text("End Process"), role: .destructive) {
                    if let selectedPID { store.endProcess(script, expectedPID: selectedPID) }
                }
                Button(L10n.text("Cancel"), role: .cancel) { selectedPID = nil }
            } message: {
                Text(L10n.format("Force end “%@” (PID %@)? Unsaved process work may be lost.",
                                 script.name.isEmpty ? L10n.text("Untitled Script") : script.name, String(selectedPID ?? pid)))
            }
        }
    }
}
