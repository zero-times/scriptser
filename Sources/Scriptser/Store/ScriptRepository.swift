import Foundation
import os.log

/// Errors that can occur during repository operations
enum RepositoryError: LocalizedError {
    case loadFailed(underlying: Error)
    case saveFailed(underlying: Error)
    case encodingFailed(underlying: Error)
    case decodingFailed(underlying: Error)
    case directoryCreationFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let error):
            return "Failed to load scripts: \(error.localizedDescription)"
        case .saveFailed(let error):
            return "Failed to save scripts: \(error.localizedDescription)"
        case .encodingFailed(let error):
            return "Failed to encode scripts: \(error.localizedDescription)"
        case .decodingFailed(let error):
            return "Failed to decode scripts: \(error.localizedDescription)"
        case .directoryCreationFailed(let error):
            return "Failed to create config directory: \(error.localizedDescription)"
        }
    }
}

/// Handles all JSON persistence operations for scripts
@MainActor
final class ScriptRepository {
    private let logger = AppLogger.repository
    private let configURL: URL
    private let fileManager = FileManager.default

    init() throws {
        self.configURL = try Self.resolveConfigURL()
        logger.info("Repository initialized with config at: \(self.configURL.path)")
    }

    /// Load scripts from the config file
    func load() throws -> [ScriptEntry] {
        guard fileManager.fileExists(atPath: configURL.path) else {
            logger.info("No config file exists, returning empty scripts")
            return []
        }

        do {
            let data = try Data(contentsOf: configURL)
            let scripts = try JSONDecoder().decode([ScriptEntry].self, from: data)
            logger.info("Loaded \(scripts.count) scripts")
            return scripts
        } catch let error as DecodingError {
            logger.error("Decoding error: \(error.localizedDescription)")
            throw RepositoryError.decodingFailed(underlying: error)
        } catch {
            logger.error("Load error: \(error.localizedDescription)")
            throw RepositoryError.loadFailed(underlying: error)
        }
    }

    /// Save scripts to the config file
    func save(_ scripts: [ScriptEntry]) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(scripts)
            try data.write(to: configURL, options: [.atomic])
            logger.info("Saved \(scripts.count) scripts")
        } catch let error as EncodingError {
            logger.error("Encoding error: \(error.localizedDescription)")
            throw RepositoryError.encodingFailed(underlying: error)
        } catch {
            logger.error("Save error: \(error.localizedDescription)")
            throw RepositoryError.saveFailed(underlying: error)
        }
    }

    /// Export scripts to a specified URL
    func exportScripts(_ scripts: [ScriptEntry], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(scripts)
        try data.write(to: url, options: [.atomic])
        logger.info("Exported \(scripts.count) scripts to \(url.path)")
    }

    /// Import scripts from a specified URL
    func importScripts(from url: URL) throws -> [ScriptEntry] {
        let data = try Data(contentsOf: url)
        let scripts = try JSONDecoder().decode([ScriptEntry].self, from: data)
        logger.info("Imported \(scripts.count) scripts from \(url.path)")
        return scripts
    }

    /// URL to the config folder (for opening in Finder)
    var configFolderURL: URL {
        configURL.deletingLastPathComponent()
    }

    /// Resolve the config URL, creating the directory if needed
    private static func resolveConfigURL() throws -> URL {
        let fileManager = FileManager.default
        let baseDir = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let folder = baseDir.appendingPathComponent("Scriptser", isDirectory: true)
        if !fileManager.fileExists(atPath: folder.path) {
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                throw RepositoryError.directoryCreationFailed(underlying: error)
            }
        }
        return folder.appendingPathComponent("config.json")
    }
}
