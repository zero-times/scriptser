import Foundation
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

    var errorDescription: String? {
        switch self {
        case .repositoryError(let error):
            return error.localizedDescription
        case .processError(let error):
            return error.localizedDescription
        case .importError(let error):
            return "Import failed: \(error.localizedDescription)"
        case .exportError(let error):
            return "Export failed: \(error.localizedDescription)"
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
    let processManager: ProcessManager
    let settings: AppSettings

    // State
    @Published var scripts: [ScriptEntry] = []
    @Published var lastError: ScriptStoreError?
    @Published var searchQuery: String = ""

    /// Filtered scripts based on search query
    var filteredScripts: [ScriptEntry] {
        guard !searchQuery.isEmpty else { return scripts }
        let query = searchQuery.lowercased()
        return scripts.filter {
            $0.name.lowercased().contains(query) ||
            $0.command.lowercased().contains(query)
        }
    }

    init() {
        self.processManager = ProcessManager()
        self.settings = AppSettings()

        do {
            self.repository = try ScriptRepository()
            load()
            processManager.syncRunningStates(for: scripts)
        } catch {
            logger.error("Failed to initialize repository: \(error.localizedDescription)")
            if let repoError = error as? RepositoryError {
                lastError = .repositoryError(repoError)
            } else {
                lastError = .repositoryError(.loadFailed(underlying: error))
            }
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
        Task {
            do {
                try await processManager.run(script)
                // Update lastRunAt
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
    }

    func stop(_ script: ScriptEntry) {
        Task {
            await processManager.stop(script.id)
        }
    }

    func runAll() {
        scripts.filter { $0.isEnabled }.forEach { run($0) }
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
