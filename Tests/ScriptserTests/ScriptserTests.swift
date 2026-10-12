import Combine
import Foundation
import XCTest
@testable import Scriptser

final class ScriptModelTests: XCTestCase {
    func testLegacyConfigurationKeepsAutomaticExecutionOff() throws {
        let id = UUID()
        let json = """
        [{"id":"\(id)","name":"Old","command":"echo old","workingDirectory":"","isEnabled":true}]
        """
        let scripts = try JSONDecoder().decode([ScriptEntry].self, from: Data(json.utf8))
        XCTAssertEqual(scripts[0].id, id)
        XCTAssertFalse(scripts[0].runAtLaunch)
        XCTAssertTrue(scripts[0].tags.isEmpty)
    }

    func testStartupFlagAndMultilineCommandRoundTrip() throws {
        var script = ScriptEntry.empty()
        script.command = "echo first\necho second"
        script.runAtLaunch = true
        let decoded = try JSONDecoder().decode(ScriptEntry.self, from: JSONEncoder().encode(script))
        XCTAssertEqual(decoded, script)
    }

    func testBothLocalizationsHaveEveryKeyAndMatchingFormatArguments() throws {
        func strings(_ language: String) throws -> [String: String] {
            let url = try XCTUnwrap(L10n.resourceBundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "\(language).lproj"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
        }
        let english = try strings("en")
        let chinese = try strings("zh-Hans")
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        XCTAssertGreaterThan(english.count, 70)
        let regex = try NSRegularExpression(pattern: "%[@d]")
        func placeholders(_ text: String) -> [String] {
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range, in: text)!])
            }
        }
        for key in english.keys {
            XCTAssertFalse(try XCTUnwrap(chinese[key]).isEmpty)
            XCTAssertEqual(placeholders(english[key]!), placeholders(chinese[key]!), key)
        }
        XCTAssertEqual(L10n.text("Run All", language: .chinese), "全部运行")
        XCTAssertEqual(L10n.text("Run All", language: .english), "Run All")
        XCTAssertEqual(L10n.format("%d running", 2, language: .chinese), "2 个运行中")
        XCTAssertEqual(AppLanguage.systemLocalization(preferredLanguages: ["zh-TW"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.systemLocalization(preferredLanguages: ["en-GB", "zh-Hans"]), "en")
        XCTAssertEqual(AppLanguage.systemLocalization(preferredLanguages: ["fr-FR"]), "en")
    }
}

@MainActor
final class StartupTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var repository: ScriptRepository!
    private var manager: ProcessManager!
    private var scriptsToStop: [UUID] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("scriptser-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "scriptser.tests.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        repository = try ScriptRepository(configURL: directory.appendingPathComponent("config.json"))
        manager = ProcessManager(defaults: defaults)
    }

    override func tearDown() async throws {
        for id in scriptsToStop {
            let didStart = manager.status(for: id).startedAt != nil
            await manager.stop(id)
            if didStart {
                // stop() sends a signal; wait for the termination callback before
                // removing a directory the command could still be writing into.
                try await waitUntil { manager.status(for: id).exitCode != nil }
            }
        }
        defaults.removePersistentDomain(forName: suiteName)
        try FileManager.default.removeItem(at: directory)
        scriptsToStop = []
    }

    private func makeScript(_ name: String, enabled: Bool = true, startup: Bool = false) -> ScriptEntry {
        let marker = directory.appendingPathComponent(name).path
        let script = ScriptEntry(id: UUID(), name: name,
                                 command: "printf 'started\\n' >> '\(marker)'; exec /bin/sleep 30",
                                 workingDirectory: directory.path, isEnabled: enabled, runAtLaunch: startup)
        scriptsToStop.append(script.id)
        return script
    }

    private func makeStore(manager: ProcessManager? = nil) -> ScriptStore {
        ScriptStore(repository: repository,
                    settings: AppSettings(defaults: defaults, managesLoginItem: false),
                    processManager: manager ?? self.manager)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "Timed out waiting for script state")
    }

    func testLaunchRunsOnlyEnabledOptedInScriptsAndRestartDoesNotDuplicate() async throws {
        let automatic = makeScript("automatic", startup: true)
        let disabled = makeScript("disabled", enabled: false, startup: true)
        let manual = makeScript("manual")
        try repository.save([automatic, disabled, manual])
        let store = makeStore()
        try await waitUntil { store.hasCompletedStartup && FileManager.default.fileExists(atPath: directory.appendingPathComponent("automatic").path) }
        XCTAssertTrue(store.isRunning(automatic))
        XCTAssertFalse(store.isRunning(disabled))
        XCTAssertFalse(store.isRunning(manual))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("disabled").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("manual").path))
        XCTAssertNotNil(store.scripts.first { $0.id == automatic.id }?.lastRunAt)

        let recoveredManager = ProcessManager(defaults: defaults)
        let restartedStore = makeStore(manager: recoveredManager)
        try await waitUntil { restartedStore.hasCompletedStartup }
        XCTAssertTrue(restartedStore.isRunning(automatic))
        do {
            try await recoveredManager.run(automatic)
            XCTFail("Recovered scripts must reject duplicate execution")
        } catch ProcessError.alreadyRunning { }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("automatic"), encoding: .utf8), "started\n")

        var updated = manual
        updated.runAtLaunch = true
        store.upsert(updated)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(store.isRunning(updated), "Editing the startup switch must not run a script immediately")
    }

    func testFailedAutomaticScriptSurfacesErrorAndDoesNotPreventOtherStarts() async throws {
        var invalid = makeScript("invalid", startup: true)
        invalid.workingDirectory = directory.appendingPathComponent("missing").path
        let valid = makeScript("valid", startup: true)
        try repository.save([invalid, valid])
        let store = makeStore()
        try await waitUntil { store.hasCompletedStartup }
        XCTAssertEqual(store.status(for: invalid).status, .failed)
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(store.isRunning(valid))
    }

    func testConcurrentManualRunIsReservedBeforeSuspending() async throws {
        let script = makeScript("concurrent")
        let first = Task { try await manager.run(script) }
        try await waitUntil { manager.isRunning(script.id) }
        do {
            try await manager.run(script)
            XCTFail("A second run must not start another process")
        } catch ProcessError.alreadyRunning { }
        try await first.value
    }

    func testSettingsPersistLanguageAndProcessChangesReachCoordinator() async throws {
        let settings = AppSettings(defaults: defaults, managesLoginItem: false)
        settings.language = .chinese
        XCTAssertEqual(AppSettings(defaults: defaults, managesLoginItem: false).language, .chinese)
        let store = makeStore()
        try await waitUntil { store.hasCompletedStartup }
        var changes = 0
        let subscription = store.objectWillChange.sink { changes += 1 }
        let script = makeScript("notify")
        try await manager.run(script)
        XCTAssertGreaterThan(changes, 0)
        await manager.stop(script.id)
        try await waitUntil { manager.status(for: script.id).status == .stopped }
        withExtendedLifetime(subscription) { }
    }
}
