import SwiftUI
import UniformTypeIdentifiers

/// Main script management window.
struct ScriptManagerView: View {
    @EnvironmentObject private var store: ScriptStore
    @State private var editingScript: ScriptEntry?
    @State private var viewingOutputScript: ScriptEntry?
    @State private var scriptToDelete: ScriptEntry?
    @State private var showingDeleteConfirmation = false
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var selectedScriptId: UUID?
    @State private var filter: ScriptFilter = .all
    @FocusState private var searchFocused: Bool

    private enum ScriptFilter: String, CaseIterable, Identifiable {
        case all = "All Scripts"
        case running = "Running"
        case startup = "At Launch"
        var id: String { rawValue }
    }

    private var visibleScripts: [ScriptEntry] {
        store.filteredScripts.filter { script in
            switch filter {
            case .all: return true
            case .running: return store.isRunning(script)
            case .startup: return script.runAtLaunch
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            headerView
            HStack {
                Picker(L10n.text("Filter"), selection: $filter) {
                    ForEach(ScriptFilter.allCases) { option in
                        Text(L10n.text(option.rawValue)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .id(store.settings.language)
                .frame(maxWidth: 360)
                Spacer()
                Text(L10n.format("%d shown", visibleScripts.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            scriptListView
            footerView
            Divider()
            settingsView
            UpdateControlsView()
        }
        .padding(20)
        .frame(minWidth: 780, minHeight: 540)
        .sheet(item: $editingScript) { script in
            ScriptEditorView(script: script) { store.upsert($0) }
        }
        .sheet(item: $viewingOutputScript) { OutputViewerView(script: $0) }
        .confirmationDialog(
            L10n.text("Delete Script"),
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("Delete"), role: .destructive) {
                if let script = scriptToDelete { store.remove(script) }
                scriptToDelete = nil
            }
            Button(L10n.text("Cancel"), role: .cancel) { scriptToDelete = nil }
        } message: {
            Text(L10n.format("Delete “%@”? This action cannot be undone.", displayName(scriptToDelete)))
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): store.importScripts(from: url)
            case .failure(let error): store.lastError = .importError(error)
            }
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: ScriptsDocument(scripts: store.scripts),
            contentType: .json,
            defaultFilename: "scripts-export"
        ) { result in
            if case .failure(let error) = result { store.lastError = .exportError(error) }
        }
        .errorAlert($store.lastError)
    }

    private var headerView: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Scripts")).font(.title2.weight(.semibold))
                Text(L10n.format("%d scripts · %d running", store.scripts.count, store.scripts.filter { store.isRunning($0) }.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            TextField(L10n.text("Search scripts..."), text: $store.searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($searchFocused)
            Button { searchFocused = true } label: { EmptyView() }
                .keyboardShortcut("f", modifiers: .command)
                .hidden().frame(width: 0, height: 0).accessibilityHidden(true)
            Button { editingScript = .empty() } label: {
                Label(L10n.text("Add Script"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    private var scriptListView: some View {
        List(selection: $selectedScriptId) {
            ForEach(visibleScripts) { script in
                ScriptManagerRow(
                    script: script,
                    onEdit: { editingScript = script },
                    onViewOutput: { viewingOutputScript = script },
                    onDelete: { requestDelete(script) }
                )
                .tag(script.id)
                .contextMenu {
                    Button(L10n.text("Edit")) { editingScript = script }
                    Button(L10n.text("Output")) { viewingOutputScript = script }
                    Divider()
                    if store.isRunning(script) {
                        Button(L10n.text("Stop")) { store.stop(script) }
                    } else {
                        Button(L10n.text("Run")) { store.run(script) }
                            .disabled(!script.isEnabled || !store.isReady)
                    }
                    Divider()
                    Button(L10n.text("Delete"), role: .destructive) { requestDelete(script) }
                }
            }
            .onDelete { offsets in
                if let index = offsets.first { requestDelete(visibleScripts[index]) }
            }
        }
        .listStyle(.inset)
        .overlay {
            if visibleScripts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: store.scripts.isEmpty ? "terminal" : "magnifyingglass")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text(L10n.text(store.scripts.isEmpty ? "No scripts yet" : "No matching scripts"))
                        .font(.headline)
                    Text(L10n.text(store.scripts.isEmpty ? "Add a shell command to get started." : "Try another search or filter."))
                        .foregroundStyle(.secondary)
                    if store.scripts.isEmpty {
                        Button(L10n.text("Add Script")) { editingScript = .empty() }
                    }
                }
                .padding(20)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }

    private var footerView: some View {
        HStack {
            Button { store.runAll() } label: { Label(L10n.text("Run All"), systemImage: "play.fill") }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!store.isReady || !store.scripts.contains { $0.isEnabled && !store.isRunning($0) })
            Button { store.stopAll() } label: { Label(L10n.text("Stop All"), systemImage: "stop.fill") }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(!store.scripts.contains { store.isRunning($0) })
            Spacer()
            Menu(L10n.text("Import/Export")) {
                Button(L10n.text("Import Scripts...")) { showingImporter = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button(L10n.text("Export Scripts...")) { showingExporter = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            Button(L10n.text("Open Config Folder")) { store.openConfigFolder() }
        }
    }

    private var settingsView: some View {
        HStack(spacing: 20) {
            Toggle(L10n.text("Launch at Login"), isOn: Binding(
                get: { store.settings.launchAtLoginEnabled },
                set: { store.settings.launchAtLoginEnabled = $0 }
            ))
            .help(L10n.text("Open Scriptser automatically when you log in to your Mac."))
            Spacer()
            Picker(L10n.text("Language"), selection: Binding(
                get: { store.settings.language },
                set: { store.settings.language = $0 }
            )) {
                ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
            }
            .frame(width: 220)
            .id(store.settings.language)
        }
    }

    private func requestDelete(_ script: ScriptEntry) {
        scriptToDelete = script
        showingDeleteConfirmation = true
    }

    private func displayName(_ script: ScriptEntry?) -> String {
        guard let script, !script.name.isEmpty else { return L10n.text("Untitled Script") }
        return script.name
    }
}

struct ScriptManagerRow: View {
    @EnvironmentObject private var store: ScriptStore
    let script: ScriptEntry
    let onEdit: () -> Void
    let onViewOutput: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let state = store.status(for: script)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(script.name.isEmpty ? L10n.text("Untitled Script") : script.name)
                    .font(.headline).lineLimit(1)
                if !script.isEnabled {
                    Text(L10n.text("Disabled")).font(.caption).foregroundStyle(.secondary)
                }
                if script.runAtLaunch {
                    Image(systemName: "power")
                        .foregroundStyle(.secondary)
                        .help(L10n.text("Run when Scriptser launches"))
                        .accessibilityLabel(L10n.text("Run when Scriptser launches"))
                }
                Spacer()
                StatusBadge(status: state.status).font(.caption)
                actionButtons
            }
            Text(script.command)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(1)
            HStack {
                if !script.workingDirectory.isEmpty {
                    Label(script.workingDirectory, systemImage: "folder")
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let lastRun = state.startedAt ?? script.lastRunAt {
                    Text(L10n.format("Last: %@", L10n.relativeDate(lastRun)))
                }
                if let duration = state.formattedDuration { Text(duration).monospacedDigit() }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button(action: onEdit) { Image(systemName: "pencil") }
                .help(L10n.text("Edit")).accessibilityLabel(L10n.text("Edit"))
            Button(action: onViewOutput) { Image(systemName: "text.alignleft") }
                .help(L10n.text("Output")).accessibilityLabel(L10n.text("Output"))
            if store.isRunning(script) {
                Button(L10n.text("Stop")) { store.stop(script) }
            } else {
                Button(L10n.text("Run")) { store.run(script) }
                    .disabled(!script.isEnabled || !store.isReady)
            }
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .help(L10n.text("Delete")).accessibilityLabel(L10n.text("Delete"))
        }
        .buttonStyle(.borderless)
    }
}

struct ErrorAlertModifier: ViewModifier {
    @Binding var error: ScriptStoreError?

    func body(content: Content) -> some View {
        content.alert(
            L10n.text("Error"),
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }),
            presenting: error
        ) { _ in
            Button(L10n.text("OK"), role: .cancel) { error = nil }
        } message: { Text($0.localizedDescription) }
    }
}

extension View {
    func errorAlert(_ error: Binding<ScriptStoreError?>) -> some View {
        modifier(ErrorAlertModifier(error: error))
    }
}
