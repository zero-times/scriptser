import AppKit
import CoreFoundation
import Foundation

struct ControlError: LocalizedError {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var errorDescription: String? { message }
}

/// All operations use the same store and process manager as the app interface.
@MainActor
final class ControlAPI {
    private let store: ScriptStore
    private var updateTask: Task<Void, Never>?

    init(store: ScriptStore) { self.store = store }

    func handle(_ data: Data) async -> Data {
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(request.keys).isSubset(of: ["version", "method", "params"]),
                  let version = request["version"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
                  let method = request["method"] as? String else {
                throw ControlError("invalid_request", "Expected {version:1, method:string, params:object}.")
            }
            let params: [String: Any]
            if let value = request["params"] {
                guard let object = value as? [String: Any] else { throw ControlError("invalid_params", "params must be an object.") }
                params = object
            } else { params = [:] }
            let result = try await dispatch(method, Params(params))
            return try JSONSerialization.data(withJSONObject: ["ok": true, "result": result], options: [.sortedKeys])
        } catch { return Self.failure(error) }
    }

    nonisolated static func failure(_ error: Error) -> Data {
        let code = (error as? ControlError)?.code ?? (error is DecodingError ? "invalid_params" : "operation_failed")
        return (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": ["code": code, "message": error.localizedDescription]], options: [.sortedKeys]))
            ?? Data("{\"ok\":false,\"error\":{\"code\":\"internal_error\",\"message\":\"Response encoding failed\"}}".utf8)
    }

    private func dispatch(_ method: String, _ p: Params) async throws -> Any {
        if method == "status" {
            try p.only([])
            return ["protocolVersion": 1, "version": store.updateManager.currentVersion,
                    "bundleID": Bundle.main.bundleIdentifier ?? "", "ready": store.isReady,
                    "startupComplete": store.hasCompletedStartup, "scriptCount": store.scripts.count,
                    "runningCount": store.scripts.filter { store.isRunning($0) }.count,
                    "configDirectory": store.controlConfigDirectory?.path ?? "",
                    "lastError": nullable(store.lastError?.localizedDescription)] as [String: Any]
        }
        guard store.hasCompletedStartup else { throw ControlError("not_ready", "Scriptser is recovering processes. Retry status before sending an operation.") }
        switch method {
        case "scripts.list":
            try p.only([])
            return try store.scripts.map { try scriptInfo($0, includeDefinition: false) }
        case "scripts.get":
            try p.only(["id"])
            return try scriptInfo(script(p), includeDefinition: true)
        case "scripts.upsert":
            try p.only(["id", "name", "notes", "command", "workingDirectory", "isEnabled", "runAtLaunch", "tags"])
            let existing = try p.optionalID().map { id -> ScriptEntry in
                guard let script = store.scripts.first(where: { $0.id == id }) else { throw ControlError("not_found", "No script with this ID. Omit id to create a script.") }
                return script
            }
            var entry = existing ?? .empty()
            if let value = try p.string("name") { entry.name = value }
            if let value = try p.string("notes") { entry.notes = value }
            if let value = try p.string("command") { entry.command = value }
            if let value = try p.string("workingDirectory") { entry.workingDirectory = value }
            if let value = try p.bool("isEnabled") { entry.isEnabled = value }
            if let value = try p.bool("runAtLaunch") { entry.runAtLaunch = value }
            if let value = p.values["tags"] {
                guard let tags = value as? [String] else { throw ControlError("invalid_params", "tags must be an array of strings.") }
                entry.tags = tags
            }
            guard !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !entry.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ControlError("invalid_params", "name and command must not be empty.")
            }
            var entries = store.scripts
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
            else { entries.append(entry) }
            try store.controlCommit(entries)
            return try scriptInfo(entry, includeDefinition: true)
        case "scripts.delete":
            try p.only(["id"])
            let entry = try script(p)
            guard !store.isRunning(entry) else { throw ControlError("running", "Stop this script before deleting it.") }
            try store.controlCommit(store.scripts.filter { $0.id != entry.id })
            return ["deleted": entry.id.uuidString]
        case "scripts.run":
            try p.only(["id"])
            let entry = try script(p)
            try await store.controlRun(entry)
            return try scriptInfo(entry, includeDefinition: false)
        case "scripts.stop":
            try p.only(["id"])
            let entry = try script(p)
            await store.processManager.stop(entry.id)
            return try scriptInfo(entry, includeDefinition: false)
        case "scripts.end":
            try p.only(["id", "expectedPID"])
            let entry = try script(p)
            let pid = try p.integer("expectedPID", required: true)!
            guard pid > 0, pid <= Int(Int32.max) else { throw ControlError("invalid_params", "expectedPID must be a positive Int32.") }
            try await store.processManager.endProcess(entry.id, expectedPID: Int32(pid))
            return try scriptInfo(entry, includeDefinition: false)
        case "scripts.run-all", "scripts.stop-all":
            try p.only([])
            var results: [[String: Any]] = []
            for entry in store.scripts {
                do {
                    if method == "scripts.run-all" {
                        guard entry.isEnabled, !store.isRunning(entry) else { continue }
                        try await store.controlRun(entry)
                    } else { await store.processManager.stop(entry.id) }
                    results.append(["id": entry.id.uuidString, "ok": true])
                } catch { results.append(["id": entry.id.uuidString, "ok": false, "message": error.localizedDescription]) }
            }
            return results
        case "scripts.output", "scripts.clear-output":
            try p.only(["id"])
            let entry = try script(p)
            if method == "scripts.clear-output" { await store.clearOutput(for: entry) }
            return ["id": entry.id.uuidString, "output": await store.getOutput(for: entry)]
        case "scripts.import":
            try p.only(["path", "strategy"])
            let path = try p.path("path")
            let strategy = try p.string("strategy", required: true)!
            let imported = try JSONDecoder().decode([ScriptEntry].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard Set(imported.map(\.id)).count == imported.count else { throw ControlError("invalid_params", "Import contains duplicate IDs.") }
            var entries = store.scripts
            switch strategy {
            case "replace":
                let kept = Set(imported.map(\.id))
                guard !entries.contains(where: { !kept.contains($0.id) && store.isRunning($0) }) else {
                    throw ControlError("running", "Stop scripts removed by this import first.")
                }
                entries = imported
            case "append":
                for var entry in imported { entry.id = UUID(); entries.append(entry) }
            case "merge":
                for entry in imported {
                    if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
                    else { entries.append(entry) }
                }
            default: throw ControlError("invalid_params", "strategy must be append, merge, or replace.")
            }
            try store.controlCommit(entries)
            return ["imported": imported.count, "total": entries.count]
        case "scripts.export":
            try p.only(["path"])
            let url = URL(fileURLWithPath: try p.path("path"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(store.scripts).write(to: url, options: .atomic)
            return ["path": url.path, "count": store.scripts.count]
        case "settings.get":
            try p.only([])
            return settingsInfo()
        case "settings.update":
            try p.only(["language", "launchAtLoginEnabled", "outputBufferSize", "skillDirectory"])
            let language = try p.string("language")
            if let language, AppLanguage(rawValue: language) == nil { throw ControlError("invalid_params", "language must be system, en, or zh-Hans.") }
            let login = try p.bool("launchAtLoginEnabled")
            let size = try p.integer("outputBufferSize")
            if let size, !(1000...1_000_000).contains(size) { throw ControlError("invalid_params", "outputBufferSize must be between 1000 and 1000000.") }
            let directory = try p.string("skillDirectory")
            if let directory { try Params.validatePath(directory) }
            store.settings.lastError = nil
            if let language { store.settings.language = AppLanguage(rawValue: language)! }
            if let directory { store.settings.skillDirectory = directory }
            if let size { store.settings.outputBufferSize = size }
            if let login { store.settings.launchAtLoginEnabled = login }
            if let error = store.settings.lastError { throw ControlError("settings_failed", error) }
            return settingsInfo()
        case "skill.preview":
            try p.only([])
            return ["name": store.skillManager.skillName, "content": try store.skillManager.preview()]
        case "skill.generate":
            try p.only(["directory"])
            let directory = try p.string("directory") ?? store.settings.skillDirectory
            try Params.validatePath(directory)
            let url = try store.skillManager.generate(in: directory)
            return ["path": url.path]
        case "updates.status":
            try p.only([])
            return updateInfo()
        case "updates.check", "updates.download", "updates.install":
            try p.only(method == "updates.download" ? ["path"] : [])
            guard updateTask == nil else { throw ControlError("busy", "An update operation is in progress. Poll updates.status.") }
            let manager = store.updateManager
            guard !manager.isDownloading, !manager.isApplyingUpdate, manager.state != .checking else {
                throw ControlError("busy", "An update operation is in progress.")
            }
            var destination: URL?
            if method != "updates.check" {
                guard manager.state == .available, manager.package != nil else { throw ControlError("no_update", "Check for an available update first.") }
                if method == "updates.download" { destination = URL(fileURLWithPath: try p.path("path")) }
                if method == "updates.install", !manager.canApplyUpdateInPlace { throw ControlError("unsupported", "This app cannot update itself in place.") }
            }
            updateTask = Task { [weak self] in
                switch method {
                case "updates.check": await manager.checkForUpdates()
                case "updates.download": await manager.downloadUpdate(to: destination!)
                default: await manager.installUpdateAndRestart()
                }
                self?.updateTask = nil
            }
            return ["accepted": true, "poll": "updates.status"]
        case "app.quit":
            try p.only([])
            // Let the socket response flush before terminating the app. Managed processes stay alive.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return ["accepted": true]
        default: throw ControlError("unknown_method", "Unknown method: \(method)")
        }
    }

    private func script(_ p: Params) throws -> ScriptEntry {
        guard let id = try p.optionalID() else { throw ControlError("invalid_params", "id is required.") }
        guard let entry = store.scripts.first(where: { $0.id == id }) else { throw ControlError("not_found", "No script with this ID.") }
        return entry
    }

    private func scriptInfo(_ entry: ScriptEntry, includeDefinition: Bool) throws -> [String: Any] {
        let state = store.status(for: entry)
        var result: [String: Any] = ["id": entry.id.uuidString, "name": entry.name, "notes": entry.notes,
            "isEnabled": entry.isEnabled, "runAtLaunch": entry.runAtLaunch, "tags": entry.tags,
            "state": ["status": state.status.rawValue, "message": state.lastMessage,
                      "pid": nullable(state.pid), "exitCode": nullable(state.exitCode),
                      "startedAt": date(state.startedAt), "endedAt": date(state.endedAt)],
            "createdAt": date(entry.createdAt), "lastRunAt": date(entry.lastRunAt)]
        if includeDefinition { result["command"] = entry.command; result["workingDirectory"] = entry.workingDirectory }
        return result
    }

    private func settingsInfo() -> [String: Any] {
        ["language": store.settings.language.rawValue, "launchAtLoginEnabled": store.settings.launchAtLoginEnabled,
         "loginItemStatus": store.settings.loginItemStatusName,
         "outputBufferSize": store.settings.outputBufferSize, "skillDirectory": store.settings.skillDirectory]
    }

    private func updateInfo() -> [String: Any] {
        let manager = store.updateManager
        return ["currentVersion": manager.currentVersion, "state": String(describing: manager.state),
                "phase": String(describing: manager.phase), "busy": updateTask != nil || manager.isDownloading || manager.isApplyingUpdate || manager.state == .checking,
                "latestVersion": nullable(manager.latestRelease?.tagName),
                "releaseURL": nullable(manager.latestRelease?.htmlURL.absoluteString),
                "downloadProgress": nullable(manager.downloadProgress), "downloadedPath": nullable(manager.downloadedURL?.path),
                "canInstall": manager.canApplyUpdateInPlace, "lastError": nullable(manager.lastError?.localizedDescription)]
    }

    private func date(_ value: Date?) -> Any { value.map { ISO8601DateFormatter().string(from: $0) } ?? (NSNull() as Any) }
    private func nullable<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
}

private struct Params {
    let values: [String: Any]
    init(_ values: [String: Any]) { self.values = values }
    func only(_ allowed: Set<String>) throws {
        let unknown = Set(values.keys).subtracting(allowed)
        guard unknown.isEmpty else { throw ControlError("invalid_params", "Unknown parameters: \(unknown.sorted().joined(separator: ", "))") }
    }
    func string(_ key: String, required: Bool = false) throws -> String? {
        guard let value = values[key] else {
            if required { throw ControlError("invalid_params", "\(key) is required.") }; return nil
        }
        guard let string = value as? String else { throw ControlError("invalid_params", "\(key) must be a string.") }
        return string
    }
    func bool(_ key: String) throws -> Bool? {
        guard let value = values[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw ControlError("invalid_params", "\(key) must be a boolean.") }
        return number.boolValue
    }
    func integer(_ key: String, required: Bool = false) throws -> Int? {
        guard let value = values[key] else {
            if required { throw ControlError("invalid_params", "\(key) is required.") }; return nil
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(number.stringValue) else { throw ControlError("invalid_params", "\(key) must be an integer.") }
        return integer
    }
    func optionalID() throws -> UUID? {
        guard let raw = try string("id") else { return nil }
        guard let id = UUID(uuidString: raw) else { throw ControlError("invalid_params", "id must be a UUID.") }
        return id
    }
    func path(_ key: String) throws -> String {
        let value = try string(key, required: true)!
        try Self.validatePath(value)
        return value
    }
    static func validatePath(_ value: String) throws {
        guard value.hasPrefix("/"), !value.utf8.contains(0) else { throw ControlError("invalid_params", "Use an absolute filesystem path.") }
    }
}
