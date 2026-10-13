import Darwin
import Foundation
import XCTest
@testable import Scriptser

@MainActor
final class ProcessDetailsTests: XCTestCase {
    func testPIDRecoveryAndForceEndRejectsStaleConfirmation() async throws {
        let suite = "scriptser.pid-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ProcessManager(defaults: defaults)
        let script = ScriptEntry(id: UUID(), name: "PID test", command: "exec /bin/sleep 30", workingDirectory: "", isEnabled: true)
        try await manager.run(script)
        let pid = try XCTUnwrap(manager.status(for: script.id).pid)
        defer { if manager.isRunning(script.id) { kill(pid, SIGKILL) } }
        XCTAssertGreaterThan(pid, 0)
        let recovered = ProcessManager(defaults: defaults)
        await recovered.syncRunningStates(for: [script])
        XCTAssertEqual(recovered.status(for: script.id).pid, pid)
        do {
            try await manager.endProcess(script.id, expectedPID: pid + 1)
            XCTFail("A mismatched PID must not receive a signal")
        } catch ProcessError.notRunning { }
        XCTAssertEqual(kill(pid, 0), 0)
        try await recovered.endProcess(script.id, expectedPID: pid)
        XCTAssertEqual(recovered.status(for: script.id).status, .stopped)
        XCTAssertNil(recovered.status(for: script.id).pid)
        let deadline = Date().addingTimeInterval(5)
        while manager.status(for: script.id).exitCode == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // The original manager observes an external signal; a restarted app only has the recovered manager.
        XCTAssertEqual(manager.status(for: script.id).status, .failed)
        XCTAssertNil(manager.status(for: script.id).pid)
        let afterExit = ProcessManager(defaults: defaults)
        await afterExit.syncRunningStates(for: [script])
        XCTAssertNil(afterExit.status(for: script.id).pid)
        do {
            try await manager.endProcess(script.id, expectedPID: pid)
            XCTFail("An exited process must not receive a signal")
        } catch ProcessError.notRunning { }
    }

    func testOwnedForceEndClearsPIDAndPublishesStopped() async throws {
        let suite = "scriptser.force-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ProcessManager(defaults: defaults)
        let script = ScriptEntry(id: UUID(), name: "Force test", command: "exec /bin/sleep 30", workingDirectory: "", isEnabled: true)
        try await manager.run(script)
        let pid = try XCTUnwrap(manager.status(for: script.id).pid)
        defer { if manager.isRunning(script.id) { kill(pid, SIGKILL) } }
        try await manager.endProcess(script.id, expectedPID: pid)
        let deadline = Date().addingTimeInterval(5)
        while manager.status(for: script.id).exitCode == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(manager.status(for: script.id).status, .stopped)
        XCTAssertEqual(manager.status(for: script.id).exitCode, Int(SIGKILL))
        XCTAssertNil(manager.status(for: script.id).pid)
    }
}
