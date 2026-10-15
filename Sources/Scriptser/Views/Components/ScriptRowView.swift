import SwiftUI

/// Shared compact presentation for Manager and the menu bar.
struct ScriptRowView: View {
    @EnvironmentObject private var store: ScriptStore
    let script: ScriptEntry
    @Binding var isExpanded: Bool
    let onEdit: () -> Void
    var onViewOutput: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    @State private var isHovered = false

    private var name: String { script.name.isEmpty ? L10n.text("Untitled Script") : script.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { isExpanded.toggle() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name)
                                .font(.body.weight(.medium))
                                .foregroundStyle(script.isEnabled ? .primary : .secondary)
                                .lineLimit(1)
                            if !script.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(script.notes)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        if script.runAtLaunch {
                            Image(systemName: "power")
                                .font(.caption).foregroundStyle(.secondary)
                                .help(L10n.text("Run when Scriptser launches"))
                                .accessibilityLabel(L10n.text("Run when Scriptser launches"))
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.text(isExpanded ? "Hide Details" : "Show Details"))
                .accessibilityLabel(L10n.format("Details: %@", name))
                .accessibilityValue(L10n.text(isExpanded ? "Expanded" : "Collapsed"))
                .contextMenu { rowActions }

                ScriptRunButton(script: script)
                Menu {
                    rowActions
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L10n.text("More Actions"))
                .accessibilityLabel(L10n.format("Actions: %@", name))
            }

            if isExpanded {
                Divider()
                details
                    .padding(.leading, 20)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? Color.primary.opacity(0.04) : .clear))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityActions { rowActions }
    }

    @ViewBuilder
    private var rowActions: some View {
        Button(L10n.text(isExpanded ? "Hide Details" : "Show Details")) { isExpanded.toggle() }
        Button(L10n.text("Edit"), action: onEdit)
        if let onViewOutput { Button(L10n.text("Output"), action: onViewOutput) }
        Divider()
        Button(L10n.text(store.isRunning(script) ? "Stop" : "Run")) {
            if store.isRunning(script) { store.stop(script) } else { store.run(script) }
        }
        .disabled(!store.isRunning(script) && (!script.isEnabled || !store.isReady))
        if let onDelete {
            Divider()
            Button(L10n.text("Delete"), role: .destructive, action: onDelete)
        }
    }

    private var details: some View {
        let state = store.status(for: script)
        return VStack(alignment: .leading, spacing: 12) {
            if !script.notes.isEmpty { detailField("Notes", value: script.notes) }
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("Command")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(script.command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
            detailField("Working Directory (optional)", value: script.workingDirectory.isEmpty
                        ? L10n.text("Default directory") : script.workingDirectory)
            if !script.tags.isEmpty { detailField("Tags", value: script.tags.joined(separator: ", ")) }
            HStack(spacing: 12) {
                StatusBadge(status: state.status)
                if !script.isEnabled { Text(L10n.text("Disabled")) }
                if let duration = state.formattedDuration { Text(duration).monospacedDigit() }
            }
            .font(.caption)
            if let lastRun = state.startedAt ?? script.lastRunAt {
                Text(L10n.format("Last: %@", L10n.relativeDate(lastRun)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !state.lastMessage.isEmpty {
                Text(state.lastMessage).font(.caption).textSelection(.enabled)
            }
            ProcessDetailsView(script: script)
            HStack(spacing: 12) {
                Button(action: onEdit) { Label(L10n.text("Edit"), systemImage: "pencil") }
                if let onViewOutput {
                    Button(action: onViewOutput) { Label(L10n.text("Output"), systemImage: "text.alignleft") }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func detailField(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text(title)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption).textSelection(.enabled)
        }
    }
}

/// The status itself is the primary action, with a verb and symbol in every state.
struct ScriptRunButton: View {
    @EnvironmentObject private var store: ScriptStore
    let script: ScriptEntry

    private var status: RunStatus { store.status(for: script).status }
    private var isRunning: Bool { store.isRunning(script) }

    private var title: String {
        if isRunning { return L10n.text("Running · Stop") }
        if !script.isEnabled { return L10n.text("Disabled") }
        switch status {
        case .idle: return L10n.text("Run")
        case .running: return L10n.text("Running · Stop")
        case .success: return L10n.text("Success · Run")
        case .failed: return L10n.text("Failed · Retry")
        case .stopped: return L10n.text("Stopped · Run")
        }
    }

    var body: some View {
        Button {
            if isRunning { store.stop(script) } else { store.run(script) }
        } label: {
            Label(title, systemImage: isRunning ? "stop.fill" : "play.fill")
                .font(.callout.weight(.medium))
                .frame(width: 128)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .tint(isRunning ? .orange : (status == .idle ? .accentColor : status.color))
        .disabled(!isRunning && (!script.isEnabled || !store.isReady))
        .help(L10n.format("%@: %@", script.name.isEmpty ? L10n.text("Untitled Script") : script.name, title))
        .accessibilityLabel(L10n.format("%@: %@", script.name.isEmpty ? L10n.text("Untitled Script") : script.name, title))
        .accessibilityValue(L10n.text(status.localizationKey))
    }
}
