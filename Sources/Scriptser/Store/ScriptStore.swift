import Foundation
import Combine
import AppKit
import SwiftUI
import os.log
import UniformTypeIdentifiers

/// Errors that can occur in ScriptStore operations
enum ScriptStoreError: LocalizedError {
    case repositoryError(RepositoryError)
    case processError(ProcessError)
    case importError(Error)
    case exportError(Error)
    case settingsError(String)
    case updateError(AppUpdateError)
    case skillError(SkillError)

    var errorDescription: String? {
        switch self {
        case .repositoryError(let error):
            return error.localizedDescription
        case .processError(let error):
            return error.localizedDescription
        case .importError(let error):
            return L10n.format("Import failed: %@", error.localizedDescription)
        case .exportError(let error):
            return L10n.format("Export failed: %@", error.localizedDescription)
        case .settingsError(let message):
            return message
        case .updateError(let error):
            return error.localizedDescription
        case .skillError(let error):
            return error.localizedDescription
        }
    }
}

/// Import merge strategy for importing scripts
enum ImportMergeStrategy {
    case replace
    case append
    case merge
}

/// Thin coordinator that composes Repository, ProcessManager, and Settings
@MainActor
final class ScriptStore: ObservableObject {
    private let logger = AppLogger.general

    // Dependencies
    private var repository: ScriptRepository?
    private var configLoadedSuccessfully = false
    let processManager: ProcessManager
    let settings: AppSettings
    let updateManager: AppUpdateManager
    let skillManager = SkillManager()
    private var subscriptions = Set<AnyCancellable>()

    // State
    @Published var scripts: [ScriptEntry] = []
    @Published var editingScript: ScriptEntry?
    @Published var lastError: ScriptStoreError?
    @Published var searchQuery: String = ""
    @Published private(set) var isReady = false
    @Published private(set) var hasCompletedStartup = false

    /// Filtered scripts based on search query
    var filteredScripts: [ScriptEntry] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return scripts }
        return scripts.filter {
            $0.name.lowercased().contains(query) ||
            $0.notes.lowercased().contains(query) ||
            $0.command.lowercased().contains(query) ||
            $0.workingDirectory.lowercased().contains(query) ||
            $0.tags.contains { $0.lowercased().contains(query) }
        }
    }

    init(repository: ScriptRepository? = nil, configURL: URL? = nil, settings: AppSettings? = nil,
         processManager: ProcessManager? = nil, updateManager: AppUpdateManager? = nil) {
        self.processManager = processManager ?? ProcessManager()
        self.settings = settings ?? AppSettings()
        self.updateManager = updateManager ?? AppUpdateManager()

        // Nested ObservableObjects must invalidate the coordinator's views too.
        self.processManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        self.settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        self.settings.$outputBufferSize
            .sink { [weak self] size in self?.processManager.outputBufferSize = max(1000, min(size, 1_000_000)) }
            .store(in: &subscriptions)
        self.settings.$lastError
            .compactMap { $0 }
            .sink { [weak self] message in self?.lastError = .settingsError(message) }
            .store(in: &subscriptions)
        self.updateManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)

        do {
            self.repository = try repository ?? ScriptRepository(configURL: configURL)
            load()
            Task {
                // Complete recovery before considering any automatic execution.
                await self.processManager.syncRunningStates(for: scripts)
                isReady = true
                for script in scripts where script.isEnabled && script.runAtLaunch && !isRunning(script) {
                    await execute(script)
                }
                hasCompletedStartup = true
            }
        } catch {
            logger.error("Failed to initialize repository: \(error.localizedDescription)")
            if let repoError = error as? RepositoryError {
                lastError = .repositoryError(repoError)
            } else {
                lastError = .repositoryError(.loadFailed(underlying: error))
            }
        }

        if self.repository == nil {
            isReady = true
            hasCompletedStartup = true
        }

        logger.info("ScriptStore initialized with \(self.scripts.count) scripts")
    }

    // MARK: - Public API

    func status(for script: ScriptEntry) -> ScriptRunState {
        processManager.status(for: script.id)
    }

    func isRunning(_ script: ScriptEntry) -> Bool {
        processManager.isRunning(script.id)
    }

    func upsert(_ script: ScriptEntry) {
        if let index = scripts.firstIndex(where: { $0.id == script.id }) {
            scripts[index] = script
            logger.info("Updated script: \(script.name)")
        } else {
            scripts.append(script)
            logger.info("Added new script: \(script.name)")
        }
        save()
    }

    func remove(at offsets: IndexSet) {
        for index in offsets {
            let script = scripts[index]
            Task {
                await processManager.stop(script.id)
            }
        }
        scripts.remove(atOffsets: offsets)
        save()
    }

    func remove(_ script: ScriptEntry) {
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        Task {
            await processManager.stop(script.id)
        }
        scripts.remove(at: index)
        save()
        logger.info("Removed script: \(script.name)")
    }

    func run(_ script: ScriptEntry) {
        guard isReady else { return }
        Task { await execute(script) }
    }

    private func execute(_ script: ScriptEntry) async {
        do {
            try await processManager.run(script)
            if let index = scripts.firstIndex(where: { $0.id == script.id }) {
                scripts[index].lastRunAt = Date()
                save()
            }
        } catch {
            logger.error("Failed to run script: \(error.localizedDescription)")
            if let processError = error as? ProcessError {
                lastError = .processError(processError)
            }
        }
    }

    func stop(_ script: ScriptEntry) {
        Task {
            await processManager.stop(script.id)
        }
    }

    func runAll() {
        scripts.filter { $0.isEnabled && !isRunning($0) }.forEach { run($0) }
    }

    func endProcess(_ script: ScriptEntry, expectedPID: Int32) {
        Task {
            do { try await processManager.endProcess(script.id, expectedPID: expectedPID) }
            catch let error as ProcessError { lastError = .processError(error) }
            catch { lastError = .processError(.terminationFailed(underlying: error)) }
        }
    }

    func stopAll() {
        scripts.forEach { stop($0) }
    }

    func getOutput(for script: ScriptEntry) async -> String {
        await processManager.getOutput(for: script.id)
    }

    func clearOutput(for script: ScriptEntry) async {
        await processManager.clearOutput(for: script.id)
    }

    // MARK: - Code control

    var controlConfigDirectory: URL? { repository?.configFolderURL }

    /// Persist first so a failed disk write cannot leave the shared UI/API state ahead of disk.
    func controlCommit(_ entries: [ScriptEntry]) throws {
        guard configLoadedSuccessfully, let repository else {
            throw ControlError("repository_unavailable", "Configuration could not be loaded. Repair it before changing scripts.")
        }
        guard Set(entries.map(\.id)).count == entries.count else {
            throw ControlError("duplicate_id", "Script IDs must be unique.")
        }
        try repository.save(entries)
        scripts = entries
    }

    func controlRun(_ script: ScriptEntry) async throws {
        guard configLoadedSuccessfully else {
            throw ControlError("repository_unavailable", "Configuration could not be loaded.")
        }
        try await processManager.run(script)
        if let index = scripts.firstIndex(where: { $0.id == script.id }) {
            var entries = scripts
            entries[index].lastRunAt = Date()
            do { try controlCommit(entries) }
            catch {
                // The process has already started; never invite an automatic retry of the run.
                throw ControlError("started_persistence_failed", "Script started, but its last-run timestamp could not be saved. Inspect status before retrying. " + error.localizedDescription)
            }
        }
    }

    // MARK: - Import/Export

    func exportScripts(to url: URL) {
        do {
            try repository?.exportScripts(scripts, to: url)
            logger.info("Exported \(self.scripts.count) scripts")
        } catch {
            logger.error("Export failed: \(error.localizedDescription)")
            lastError = .exportError(error)
        }
    }

    func importScripts(from url: URL, mergeStrategy: ImportMergeStrategy = .append) {
        do {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let imported = try repository?.importScripts(from: url) ?? []

            switch mergeStrategy {
            case .replace:
                scripts = imported
            case .append:
                scripts.append(contentsOf: imported)
            case .merge:
                for script in imported {
                    if let index = scripts.firstIndex(where: { $0.id == script.id }) {
                        scripts[index] = script
                    } else {
                        scripts.append(script)
                    }
                }
            }

            save()
            logger.info("Imported \(imported.count) scripts with strategy: \(String(describing: mergeStrategy))")
        } catch {
            logger.error("Import failed: \(error.localizedDescription)")
            lastError = .importError(error)
        }
    }

    // MARK: - Utilities

    func openConfigFolder() {
        if let folder = repository?.configFolderURL {
            NSWorkspace.shared.open(folder)
        }
    }

    func clearError() {
        lastError = nil
    }

    // MARK: - Private

    private func load() {
        do {
            scripts = try repository?.load() ?? []
            configLoadedSuccessfully = repository != nil
        } catch {
            logger.error("Load failed: \(error.localizedDescription)")
            if let repoError = error as? RepositoryError {
                lastError = .repositoryError(repoError)
            } else {
                lastError = .repositoryError(.loadFailed(underlying: error))
            }
            scripts = []
        }
    }

    private func save() {
        do {
            try repository?.save(scripts)
        } catch {
            logger.error("Save failed: \(error.localizedDescription)")
            if let repoError = error as? RepositoryError {
                lastError = .repositoryError(repoError)
            } else {
                lastError = .repositoryError(.saveFailed(underlying: error))
            }
        }
    }
}

// MARK: - File Document for Export

struct ScriptsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var scripts: [ScriptEntry]

    init(scripts: [ScriptEntry]) {
        self.scripts = scripts
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        scripts = try JSONDecoder().decode([ScriptEntry].self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(scripts)
        return FileWrapper(regularFileWithContents: data)
    }
}
