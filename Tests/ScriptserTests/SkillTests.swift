import Foundation
import XCTest
@testable import Scriptser

@MainActor
final class SkillTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scriptser-skill-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testBundledSkillGeneratesAndRefreshesPreservingAdditionalFiles() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let manager = SkillManager(isDevelopmentApp: false)
        let target = try manager.generate(in: parent.path)
        let content = try String(contentsOf: target.appendingPathComponent("SKILL.md"), encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("---\nname: scriptser-control\n"))
        XCTAssertTrue(content.contains("com.ingoo.scriptser"))
        XCTAssertFalse(content.contains("{{"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("references/cli.md").path))
        let extra = target.appendingPathComponent("notes.txt")
        try "user notes".write(to: extra, atomically: true, encoding: .utf8)
        try manager.generate(in: parent.path)
        XCTAssertEqual(try String(contentsOf: extra, encoding: .utf8), "user notes")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("SKILL.md"), encoding: .utf8), content)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["scriptser-control"])
        XCTAssertTrue(manager.installationPrompt(in: parent.path).contains(target.appendingPathComponent("SKILL.md").path))
    }

    func testDevSkillTargetsOnlyDevAndDoesNotOverwriteProduction() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let production = try SkillManager(isDevelopmentApp: false).generate(in: parent.path)
        let dev = try SkillManager(isDevelopmentApp: true).generate(in: parent.path)
        XCTAssertNotEqual(production, dev)
        for file in ["SKILL.md", "references/cli.md", "scripts/scriptserctl.py"] {
            let content = try String(contentsOf: dev.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(content.contains("com.scriptser.scr1.preview"))
            if file != "scripts/scriptserctl.py" { XCTAssertTrue(content.contains("scriptser-dev-control")) }
            XCTAssertFalse(content.contains("{{"))
        }
    }

    func testUnrelatedSkillAndSymbolicLinkAreNotOverwritten() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let manager = SkillManager(isDevelopmentApp: false)
        let target = manager.destination(in: parent.path)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let entry = target.appendingPathComponent("SKILL.md")
        try "user skill".write(to: entry, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try manager.generate(in: parent.path))
        XCTAssertEqual(try String(contentsOf: entry, encoding: .utf8), "user skill")
        try FileManager.default.removeItem(at: target)
        let outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        XCTAssertThrowsError(try manager.generate(in: parent.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testMissingTemplateDoesNotCreatePartialPackage() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let missing = SkillManager(isDevelopmentApp: false, templateURL: nil)
        XCTAssertThrowsError(try missing.generate(in: parent.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    func testSelectedDirectoryIsRemembered() throws {
        let suite = "scriptser.skill-settings.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, managesLoginItem: false)
        settings.skillDirectory = "/tmp/assistant skills"
        XCTAssertEqual(AppSettings(defaults: defaults, managesLoginItem: false).skillDirectory, "/tmp/assistant skills")
    }

    func testFailedRefreshAndLinkedReferenceLeaveExistingSkillIntact() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let manager = SkillManager(isDevelopmentApp: false)
        let target = try manager.generate(in: parent.path)
        let original = try Data(contentsOf: target.appendingPathComponent("SKILL.md"))
        let badTemplate = parent.appendingPathComponent("incomplete-template")
        try FileManager.default.createDirectory(at: badTemplate, withIntermediateDirectories: false)
        try original.write(to: badTemplate.appendingPathComponent("SKILL.md"))
        XCTAssertThrowsError(try SkillManager(isDevelopmentApp: false, templateURL: badTemplate).generate(in: parent.path))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("SKILL.md")), original)
        let reference = target.appendingPathComponent("references/cli.md")
        try FileManager.default.removeItem(at: reference)
        let outside = parent.appendingPathComponent("outside.md")
        try "untouched".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: reference, withDestinationURL: outside)
        XCTAssertThrowsError(try manager.generate(in: parent.path))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched")
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("SKILL.md")), original)
    }
    func testLegacyUIUpgradeInstallsClientAndRemovesOnlyBundledGuide() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let manager = SkillManager(isDevelopmentApp: false)
        let target = manager.destination(in: parent.path)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("references"), withIntermediateDirectories: true)
        try "<!-- Generated by Scriptser: UI skill v1 -->".write(to: target.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "# Interface operations\n## Manager and menu bar".write(to: target.appendingPathComponent("references/ui.md"), atomically: true, encoding: .utf8)
        try manager.generate(in: parent.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("references/ui.md").path))
        let client = try String(contentsOf: target.appendingPathComponent("scripts/scriptserctl.py"), encoding: .utf8)
        XCTAssertTrue(client.contains("SUPPORT_NAME = \"Scriptser\""))
        XCTAssertFalse(client.contains("{{"))
        let scripts = target.appendingPathComponent("scripts")
        try FileManager.default.removeItem(at: scripts)
        let outside = parent.appendingPathComponent("outside-scripts")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: scripts, withDestinationURL: outside)
        XCTAssertThrowsError(try manager.generate(in: parent.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

}
