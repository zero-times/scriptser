import Darwin
import Foundation
import XCTest
@testable import Scriptser

@MainActor
private final class ControlHarness {
    let directory: URL
    let config: URL
    let defaults: UserDefaults
    let suite: String
    let store: ScriptStore
    let api: ControlAPI

    init() async throws {
        directory = URL(fileURLWithPath: "/tmp/ssctl-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        config = directory.appendingPathComponent("config.json")
        suite = "scriptser.control-tests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        store = ScriptStore(configURL: config, settings: AppSettings(defaults: defaults, managesLoginItem: false),
                            processManager: ProcessManager(defaults: defaults))
        api = ControlAPI(store: store)
        for _ in 0..<200 where !store.hasCompletedStartup { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(store.hasCompletedStartup)
    }

    func cleanup() {
        for entry in store.scripts { if let pid = store.status(for: entry).pid { kill(pid, SIGKILL) } }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let request = try JSONSerialization.data(withJSONObject: ["version": 1, "method": method, "params": params])
        let data = await api.handle(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func create(_ command: String = "printf CONTROL_API_OK", extras: [String: Any] = [:]) async throws -> ScriptEntry {
        var params: [String: Any] = ["name": "Control test", "command": command]
        params.merge(extras) { _, new in new }
        let response = try await call("scripts.upsert", params)
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        return try XCTUnwrap(store.scripts.last)
    }
}

@MainActor
final class ControlAPITests: XCTestCase {
    func testCRUDPersistencePartialUpdateAndStrictValidation() async throws {
        let h = try await ControlHarness()
        defer { h.cleanup() }
        let entry = try await h.create(extras: ["notes": "keep", "tags": ["service"], "runAtLaunch": true])
        var reply = try await h.call("scripts.upsert", ["id": entry.id.uuidString, "name": "Edited"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(h.store.scripts[0].notes, "keep")
        XCTAssertTrue(h.store.scripts[0].runAtLaunch)
        XCTAssertEqual(h.store.scripts[0].createdAt, entry.createdAt)
        let saved = try JSONDecoder().decode([ScriptEntry].self, from: Data(contentsOf: h.config))
        XCTAssertEqual(saved, h.store.scripts)
        for params: [String: Any] in [["id": entry.id.uuidString, "isEnabled": 1], ["id": entry.id.uuidString, "name": NSNull()], ["id": UUID().uuidString, "name": "missing"], ["id": entry.id.uuidString, "typo": true]] {
            reply = try await h.call("scripts.upsert", params)
            XCTAssertEqual(reply["ok"] as? Bool, false)
            XCTAssertEqual(h.store.scripts, saved)
        }
        reply = try await h.call("scripts.delete", ["id": entry.id.uuidString])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertTrue(h.store.scripts.isEmpty)
        XCTAssertTrue(try JSONDecoder().decode([ScriptEntry].self, from: Data(contentsOf: h.config)).isEmpty)
    }

    func testPersistenceFailureDoesNotPublishChanges() async throws {
        let h = try await ControlHarness()
        defer { h.cleanup() }
        let entry = try await h.create()
        try FileManager.default.removeItem(at: h.config)
        try FileManager.default.createDirectory(at: h.config, withIntermediateDirectories: false)
        let response = try await h.call("scripts.upsert", ["id": entry.id.uuidString, "name": "Must not publish"])
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertEqual(h.store.scripts, [entry])
    }

    func testRunOutputStopAndStalePIDAreRealProcessOperations() async throws {
        let h = try await ControlHarness()
        defer { h.cleanup() }
        let entry = try await h.create("printf CONTROL_API_OK; exec /bin/sleep 30")
        var reply = try await h.call("scripts.run", ["id": entry.id.uuidString])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let pid = try XCTUnwrap(h.store.status(for: entry).pid)
        reply = try await h.call("scripts.run", ["id": entry.id.uuidString])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        reply = try await h.call("scripts.delete", ["id": entry.id.uuidString])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        reply = try await h.call("scripts.end", ["id": entry.id.uuidString, "expectedPID": pid + 1])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(kill(pid, 0), 0)
        for _ in 0..<300 {
            if await h.store.getOutput(for: entry).contains("CONTROL_API_OK") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        reply = try await h.call("scripts.output", ["id": entry.id.uuidString])
        XCTAssertTrue(((reply["result"] as? [String: Any])?["output"] as? String)?.contains("CONTROL_API_OK") == true)
        reply = try await h.call("scripts.stop", ["id": entry.id.uuidString])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        for _ in 0..<200 where h.store.isRunning(entry) { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(h.store.status(for: entry).status, .stopped)
        XCTAssertNil(h.store.status(for: entry).pid)
        reply = try await h.call("scripts.clear-output", ["id": entry.id.uuidString])
        XCTAssertEqual((reply["result"] as? [String: Any])?["output"] as? String, "")
    }

    func testIgnoredStopKeepsRunningStateUntilForceEnd() async throws {
        let h = try await ControlHarness()
        defer { h.cleanup() }
        let entry = try await h.create("exec /usr/bin/python3 -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print(\"STOP_READY\", flush=True); time.sleep(30)'")
        _ = try await h.call("scripts.run", ["id": entry.id.uuidString])
        let pid = try XCTUnwrap(h.store.status(for: entry).pid)
        for _ in 0..<300 {
            if await h.store.getOutput(for: entry).contains("STOP_READY") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        _ = try await h.call("scripts.stop", ["id": entry.id.uuidString])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(h.store.isRunning(entry))
        XCTAssertEqual(kill(pid, 0), 0)
        let deleted = try await h.call("scripts.delete", ["id": entry.id.uuidString])
        XCTAssertEqual(deleted["ok"] as? Bool, false)
        _ = try await h.call("scripts.end", ["id": entry.id.uuidString, "expectedPID": pid])
        for _ in 0..<200 where h.store.isRunning(entry) { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(h.store.status(for: entry).status, .stopped)
    }

    func testSuccessfulExitAndNativeImportExportWithFreshAppendIDs() async throws {
        let h = try await ControlHarness()
        defer { h.cleanup() }
        let entry = try await h.create()
        _ = try await h.call("scripts.run", ["id": entry.id.uuidString])
        for _ in 0..<300 where h.store.isRunning(entry) { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(h.store.status(for: entry).exitCode, 0)
        let export = h.directory.appendingPathComponent("export.json")
        var reply = try await h.call("scripts.export", ["path": export.path])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let decoded = try JSONDecoder().decode([ScriptEntry].self, from: Data(contentsOf: export))
        XCTAssertEqual(decoded[0].id, entry.id)
        reply = try await h.call("scripts.import", ["path": export.path, "strategy": "append"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(h.store.scripts.count, 2)
        XCTAssertNotEqual(h.store.scripts[0].id, h.store.scripts[1].id)
    }

    func testSettingsValidationAndSkillGeneration() async throws {
        let h = try await ControlHarness()
        defer { h.cleanup() }
        var reply = try await h.call("settings.update", ["language": "en", "outputBufferSize": 4567])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(h.store.processManager.outputBufferSize, 4567)
        reply = try await h.call("settings.update", ["language": "zh-Hans", "outputBufferSize": true])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(h.store.settings.language, .english)
        reply = try await h.call("skill.generate", ["directory": h.directory.path])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.directory.appendingPathComponent("scriptser-control/scripts/scriptserctl.py").path))
        reply = try await h.call("updates.download", ["path": h.directory.appendingPathComponent("update.dmg").path])
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? String, "no_update")
    }

    func testMalformedProtocolDoesNotMutate() async throws {
        let h = try await ControlHarness()
        defer { h.cleanup() }
        for raw in ["not-json", "[]", "{\"version\":true,\"method\":\"scripts.list\"}", "{\"version\":1,\"method\":\"scripts.list\",\"params\":[]}", "{\"version\":2,\"method\":\"scripts.list\"}"] {
            let data = await h.api.handle(Data(raw.utf8))
            let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(reply["ok"] as? Bool, false)
        }
        let reply = try await h.call("does.not.exist")
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? String, "unknown_method")
        XCTAssertTrue(h.store.scripts.isEmpty)
    }

    func testSocketPythonClientPermissionsAndExclusiveOwnership() async throws {
        let h = try await ControlHarness()
        defer { h.cleanup() }
        let socket = h.directory.appendingPathComponent("control.sock")
        let server = LocalControlServer(socketURL: socket) { await h.api.handle($0) }
        try server.start()
        defer { server.stop() }
        let permissions = try FileManager.default.attributesOfItem(atPath: socket.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        let duplicate = LocalControlServer(socketURL: socket) { $0 }
        XCTAssertThrowsError(try duplicate.start())
        _ = try h.store.skillManager.generate(in: h.directory.path)
        let client = h.directory.appendingPathComponent("scriptser-control/scripts/scriptserctl.py")
        let result = try await python(client, ["status", "--socket", socket.path])
        XCTAssertEqual(result.0, 0, result.1)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.1.utf8)) as? [String: Any])
        XCTAssertEqual((response["result"] as? [String: Any])?["startupComplete"] as? Bool, true)
        let malformed = try await pythonCode("import socket,json,sys,time; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(0.05); s.sendall(b'bad-json\\n'); print(s.recv(4096).decode())", [socket.path])
        XCTAssertTrue(malformed.1.contains("\"ok\":false"))
        let oversized = try await pythonCode("import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(b'x'*1048577); print(s.recv(4096).decode())", [socket.path])
        XCTAssertTrue(oversized.1.contains("request_too_large"), oversized.1)
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        try duplicate.start()
        duplicate.stop()
    }

    func testStaleSocketRecoveredButRegularFilePreserved() async throws {
        let h = try await ControlHarness()
        defer { h.cleanup() }
        let socket = h.directory.appendingPathComponent("control.sock")
        _ = try await pythonCode("import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()", [socket.path])
        let server = LocalControlServer(socketURL: socket) { await h.api.handle($0) }
        try server.start()
        server.stop()
        try "keep".write(to: socket, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(try String(contentsOf: socket, encoding: .utf8), "keep")
    }

    private func python(_ client: URL, _ args: [String]) async throws -> (Int32, String) {
        try await pythonProcess([client.path] + args)
    }
    private func pythonCode(_ code: String, _ args: [String]) async throws -> (Int32, String) {
        try await pythonProcess(["-c", code] + args)
    }
    private func pythonProcess(_ args: [String]) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        await Task.detached { process.waitUntilExit() }.value
        return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
