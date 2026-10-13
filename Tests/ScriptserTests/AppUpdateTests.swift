import CryptoKit
import Foundation
import XCTest
@testable import Scriptser

final class UpdateVersionTests: XCTestCase {
    func testNumericReleaseVersionComparisonAndInvalidTags() throws {
        XCTAssertGreaterThan(try XCTUnwrap(ReleaseVersion("v1.10.0")), try XCTUnwrap(ReleaseVersion("1.9.9")))
        XCTAssertEqual(ReleaseVersion("1.2"), ReleaseVersion("1.2.0+build.4"))
        for tag in ["", "v", "+metadata", "1..2", "latest", "1.0.0-beta.1", "-1", "1.2.3.4"] {
            XCTAssertNil(ReleaseVersion(tag), tag)
        }
    }

    func testSelectsNativePackagesAndRejectsOtherPlatformsAndUntrustedURLs() throws {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data("""
        {"tag_name":"v1.1.0","html_url":"https://github.com/zero-times/scriptser/releases/tag/v1.1.0",
        "draft":false,"prerelease":false,"assets":[
          {"name":"Scriptser-linux.zip","size":12,"browser_download_url":"https://github.com/zero-times/scriptser/releases/download/v1.1.0/linux.zip"},
          {"name":"Scriptser-arm64.dmg","size":12,"browser_download_url":"https://github.com/zero-times/scriptser/releases/download/v1.1.0/arm64.dmg"},
          {"name":"Scriptser-x86_64.dmg","size":12,"browser_download_url":"https://github.com/zero-times/scriptser/releases/download/v1.1.0/x86_64.dmg"},
          {"name":"Scriptser-universal.zip","size":12,"browser_download_url":"https://github.com/zero-times/scriptser/releases/download/v1.1.0/universal.zip"},
          {"name":"Scriptser-arm64.zip","size":12,"browser_download_url":"https://evil.example/update.zip"}
        ]}
        """.utf8))
        XCTAssertEqual(release.package(for: "arm64")?.name, "Scriptser-arm64.dmg")
        XCTAssertEqual(release.package(for: "x86_64")?.name, "Scriptser-x86_64.dmg")
    }

    func testDownloadSizeAndDigestVerification() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scriptser-update-\(UUID()).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("verified package fixture".utf8)
        try data.write(to: url)
        let digest = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        func asset(size: Int64, digest: String?) -> GitHubRelease.Asset {
            .init(name: "Scriptser.zip", browserDownloadURL: URL(string: "https://github.com/zero-times/scriptser/releases/download/v1.1.0/Scriptser.zip")!, size: size, digest: digest)
        }
        XCTAssertNoThrow(try AppUpdateManager.verifyDownload(at: url, asset: asset(size: Int64(data.count), digest: digest)))
        XCTAssertThrowsError(try AppUpdateManager.verifyDownload(at: url, asset: asset(size: 999, digest: digest)))
        XCTAssertThrowsError(try AppUpdateManager.verifyDownload(at: url, asset: asset(size: Int64(data.count), digest: "sha256:wrong")))
    }
}

private final class UpdateResponseProtocol: URLProtocol {
    static var responseCode = 200
    static var responseData = Data()
    static var handler: ((URLRequest) -> (Int, Data, URL?, [String: String]))?
    static var requests: [URL] = []
    static var delay: TimeInterval = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request.url!)
        let result = Self.handler?(request) ?? (Self.responseCode, Self.responseData, nil, [:])
        let respond = {
            let response = HTTPURLResponse(url: result.2 ?? self.request.url!, statusCode: result.0, httpVersion: "HTTP/1.1", headerFields: result.3)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: result.1)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if Self.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay, execute: respond) }
        else { respond() }
    }
    override func stopLoading() { }
}

@MainActor
final class UpdateCheckTests: XCTestCase {
    override func setUp() async throws {
        UpdateResponseProtocol.handler = nil
        UpdateResponseProtocol.requests = []
        UpdateResponseProtocol.delay = 0
    }

    private func manager(installed: String = "1.0.0", tag: String = "v1.1.0", status: Int = 200, prerelease: Bool = false) -> AppUpdateManager {
        UpdateResponseProtocol.responseCode = status
        UpdateResponseProtocol.responseData = Data("""
        {"tag_name":"\(tag)","html_url":"https://github.com/zero-times/scriptser/releases/tag/\(tag)","body":"Notes","draft":false,"prerelease":\(prerelease),"assets":[]}
        """.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateResponseProtocol.self]
        return AppUpdateManager(session: URLSession(configuration: configuration), currentVersion: installed)
    }

    func testNewReleaseIsOfferedAndInstalledOrOlderVersionsAreNot() async {
        let update = manager(installed: "1.9.0", tag: "v1.10.0")
        await update.checkForUpdates()
        XCTAssertEqual(update.state, .available)
        XCTAssertEqual(update.latestRelease?.body, "Notes")
        XCTAssertNil(update.package, "A release without a macOS asset must not offer a package")
        let current = manager(installed: "1.1.0", tag: "v1.1.0")
        await current.checkForUpdates()
        XCTAssertEqual(current.state, .current)
        let older = manager(installed: "1.2.0", tag: "v1.1.0")
        await older.checkForUpdates()
        XCTAssertEqual(older.state, .current)
    }

    func testMissingReleaseAndAPIFailuresHaveDistinctStates() async {
        let missing = manager(status: 404)
        await missing.checkForUpdates()
        XCTAssertEqual(missing.state, .noRelease)
        XCTAssertNil(missing.lastError)
        let failure = manager(status: 403)
        await failure.checkForUpdates()
        XCTAssertEqual(failure.state, .failed)
        XCTAssertNotNil(failure.lastError)
        let rateLimited = manager(status: 403)
        UpdateResponseProtocol.responseData = Data(#"{"message":"API rate limit exceeded"}"#.utf8)
        await rateLimited.checkForUpdates()
        guard case .rateLimited? = rateLimited.lastError else {
            return XCTFail("Rate limiting must have an actionable message")
        }
    }

    func testVerifiedPackageIsSavedAndDamagedPackageDoesNotOverwriteDestination() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scriptser-download-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data("fixture package".utf8)
        let digest = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        UpdateResponseProtocol.responseCode = 200
        UpdateResponseProtocol.responseData = Data("""
        {"tag_name":"v1.1.0","html_url":"https://github.com/zero-times/scriptser/releases/tag/v1.1.0","draft":false,"prerelease":false,"assets":[
          {"name":"Scriptser-universal.dmg","size":\(bytes.count),"digest":"\(digest)","browser_download_url":"https://github.com/zero-times/scriptser/releases/download/v1.1.0/Scriptser-universal.dmg"}
        ]}
        """.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        let destination = folder.appendingPathComponent("saved.dmg")
        let download = AppUpdateManager(session: session, currentVersion: "1.0.0", download: { request in
            XCTAssertEqual(request.url?.host, "github.com")
            let temporary = folder.appendingPathComponent("download.tmp")
            try bytes.write(to: temporary)
            return (temporary, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await download.checkForUpdates()
        await download.downloadUpdate(to: destination)
        XCTAssertEqual(download.downloadedURL, destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertNil(download.lastError)
        XCTAssertFalse(download.isDownloading)

        let damaged = AppUpdateManager(session: session, currentVersion: "1.0.0", download: { request in
            let temporary = folder.appendingPathComponent("damaged.tmp")
            try Data("invalid".utf8).write(to: temporary)
            return (temporary, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await damaged.checkForUpdates()
        await damaged.downloadUpdate(to: destination)
        XCTAssertNil(damaged.downloadedURL)
        XCTAssertNotNil(damaged.lastError)
        XCTAssertEqual(try Data(contentsOf: destination), bytes, "Failed verification must preserve existing files")
    }

    func testRejectsPrereleaseAndMalformedVersion() async {
        let prerelease = manager(prerelease: true)
        await prerelease.checkForUpdates()
        XCTAssertEqual(prerelease.state, .failed)
        let malformed = manager(tag: "latest")
        await malformed.checkForUpdates()
        XCTAssertEqual(malformed.state, .failed)
    }

    func testConcurrentChecksAndRapidRepeatedChecksSendOneAPIRequest() async {
        let update = manager()
        UpdateResponseProtocol.delay = 0.1
        let first = Task { await update.checkForUpdates() }
        // The first task reserves the check before its network operation suspends.
        await Task.yield()
        XCTAssertEqual(update.state, .checking)
        let secondOwnsCheck = await update.checkForUpdates()
        XCTAssertFalse(secondOwnsCheck)
        _ = await first.value
        await update.checkForUpdates()
        XCTAssertEqual(UpdateResponseProtocol.requests.count, 1)
        XCTAssertEqual(update.state, .available)
    }

    func testRateLimitUsesOfficialLatestPageAndSkipsAPIUntilReset() async {
        var clock = Date(timeIntervalSince1970: 1000)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateResponseProtocol.self]
        let update = AppUpdateManager(session: URLSession(configuration: configuration), currentVersion: "0.9.0", now: { clock })
        UpdateResponseProtocol.handler = { request in
            if request.url?.host == "api.github.com" {
                return (403, Data(#"{"message":"API rate limit exceeded"}"#.utf8), nil,
                        ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "2000"])
            }
            return (200, Data("release page".utf8), URL(string: "https://github.com/zero-times/scriptser/releases/tag/v1.0.0"), [:])
        }
        await update.checkForUpdates()
        XCTAssertEqual(update.state, .available)
        XCTAssertEqual(update.latestRelease?.tagName, "v1.0.0")
        XCTAssertNil(update.lastError)
        XCTAssertTrue(update.usesWebsiteFallback)
        XCTAssertNil(update.package, "Web fallback must not invent size or digest metadata")
        await update.checkForUpdates()
        XCTAssertEqual(UpdateResponseProtocol.requests.count, 2)
        clock = clock.addingTimeInterval(61)
        await update.checkForUpdates()
        XCTAssertEqual(UpdateResponseProtocol.requests.filter { $0.host == "api.github.com" }.count, 1)
        XCTAssertEqual(UpdateResponseProtocol.requests.filter { $0.host == "github.com" }.count, 2)
        clock = Date(timeIntervalSince1970: 2001)
        await update.checkForUpdates()
        XCTAssertEqual(UpdateResponseProtocol.requests.filter { $0.host == "api.github.com" }.count, 2)
    }

    func testWebsiteFallbackRejectsUnexpectedDestinationsAndPrereleaseTags() async {
        for destination in ["https://evil.example/releases/tag/v1.0.0",
                            "http://github.com/zero-times/scriptser/releases/tag/v1.0.0",
                            "https://github.com/other/repo/releases/tag/v1.0.0",
                            "https://github.com/zero-times/scriptser/releases/tag/v1.0.0-beta.1"] {
            let update = manager(status: 429)
            UpdateResponseProtocol.handler = { request in
                if request.url?.host == "api.github.com" { return (429, Data(), nil, [:]) }
                return (200, Data(), URL(string: destination), [:])
            }
            await update.checkForUpdates()
            XCTAssertEqual(update.state, .failed, destination)
            XCTAssertNil(update.latestRelease)
        }
    }

    func testStreamedDownloadReportsProgressAndVerifies() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scriptser-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data(repeating: 0x5A, count: 512)
        let digest = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        UpdateResponseProtocol.handler = { request in
            if request.url?.host == "api.github.com" {
                let release = """
                {"tag_name":"v1.1.0","html_url":"https://github.com/zero-times/scriptser/releases/tag/v1.1.0","draft":false,"prerelease":false,"assets":[
                  {"name":"Scriptser-universal.dmg","size":\(bytes.count),"digest":"\(digest)","browser_download_url":"https://github.com/zero-times/scriptser/releases/download/v1.1.0/Scriptser-universal.dmg"}
                ]}
                """.data(using: .utf8)!
                return (200, release, nil, ["Content-Type": "application/json"])
            }
            return (200, bytes, nil, ["Content-Length": "\(bytes.count)"])
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateResponseProtocol.self]
        let update = AppUpdateManager(session: URLSession(configuration: configuration), currentVersion: "1.0.0")
        await update.checkForUpdates()
        XCTAssertEqual(update.state, .available)
        let destination = folder.appendingPathComponent("streamed.dmg")
        await update.downloadUpdate(to: destination)
        XCTAssertNil(update.lastError)
        XCTAssertEqual(update.downloadProgress, 1)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testUpdateFailureIsNotBroadcastAsAnAlertToEveryStoreView() async throws {
        let update = manager(status: 403)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "scriptser.update-alert.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let store = ScriptStore(configURL: folder.appendingPathComponent("config.json"),
                                settings: AppSettings(defaults: defaults, managesLoginItem: false),
                                processManager: ProcessManager(defaults: defaults), updateManager: update)
        await update.checkForUpdates()
        XCTAssertNotNil(update.lastError)
        XCTAssertNil(store.lastError, "Only the initiating update control should present the error")
    }
}

@MainActor
final class UpdateInstallTests: XCTestCase {
    override func setUp() async throws {
        UpdateResponseProtocol.handler = nil
        UpdateResponseProtocol.requests = []
        UpdateResponseProtocol.delay = 0
    }

    /// Builds a minimal ZIP containing a Scriptser.app bundle so the real staging
    /// pipeline (download → verify → extract → stage) can run without a DMG.
    private func fakeScriptserZip() throws -> Data {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Scriptser.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("fixture executable".utf8).write(to: app.appendingPathComponent("Executable"))
        let zipURL = root.appendingPathComponent("Scriptser-universal.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", app.path, zipURL.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return try Data(contentsOf: zipURL)
    }

    private func manager(zip: Data, tag: String = "v1.2.0", installed: String = "1.1.0",
                         launchRestartHelper: @escaping (URL, URL, URL) throws -> Void,
                         performRestart: @escaping () -> Void) -> AppUpdateManager {
        UpdateResponseProtocol.responseCode = 200
        UpdateResponseProtocol.responseData = Data("""
        {"tag_name":"\(tag)","html_url":"https://github.com/zero-times/scriptser/releases/tag/\(tag)","body":"Notes","draft":false,"prerelease":false,"assets":[
          {"name":"Scriptser-universal.zip","size":\(zip.count),"browser_download_url":"https://github.com/zero-times/scriptser/releases/download/\(tag)/Scriptser-universal.zip"}
        ]}
        """.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateResponseProtocol.self]
        return AppUpdateManager(session: URLSession(configuration: configuration),
                                currentVersion: installed,
                                download: { request in
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("scriptser-download-\(UUID().uuidString).zip")
            try zip.write(to: temporary)
            return (temporary, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        },
        canApplyUpdateInPlace: true,
        launchRestartHelper: launchRestartHelper,
        performRestart: performRestart)
    }

    func testInstallCommitsRestartAndLocksUIUntilProcessExits() async throws {
        let zip = try fakeScriptserZip()
        var restarts = 0
        var capturedTarget: URL?
        let update = manager(zip: zip,
                             launchRestartHelper: { _, target, _ in capturedTarget = target },
                             performRestart: { restarts += 1 })
        await update.checkForUpdates()
        XCTAssertEqual(update.state, .available)

        await update.installUpdateAndRestart()

        XCTAssertEqual(restarts, 1, "Restart must be committed exactly once")
        XCTAssertEqual(capturedTarget?.lastPathComponent, "Scriptser.app")
        XCTAssertEqual(update.phase, .restarting)
        XCTAssertTrue(update.isApplyingUpdate, "UI must stay locked while restarting")
        XCTAssertNil(update.lastError)

        // Clicking Install and Restart again while restarting must not re-download or relaunch.
        await update.installUpdateAndRestart()
        XCTAssertEqual(restarts, 1)
    }

    func testInstallFailureUnlocksUIAndReportsError() async throws {
        let zip = try fakeScriptserZip()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateResponseProtocol.self]
        UpdateResponseProtocol.responseCode = 200
        UpdateResponseProtocol.responseData = Data("""
        {"tag_name":"v1.2.0","html_url":"https://github.com/zero-times/scriptser/releases/tag/v1.2.0","body":"Notes","draft":false,"prerelease":false,"assets":[
          {"name":"Scriptser-universal.zip","size":\(zip.count),"browser_download_url":"https://github.com/zero-times/scriptser/releases/download/v1.2.0/Scriptser-universal.zip"}
        ]}
        """.utf8)
        let update = AppUpdateManager(session: URLSession(configuration: configuration),
                                      currentVersion: "1.1.0",
                                      download: { _ in throw URLError(.notConnectedToInternet) },
                                      canApplyUpdateInPlace: true,
                                      launchRestartHelper: { _, _, _ in },
                                      performRestart: { })
        await update.checkForUpdates()
        XCTAssertEqual(update.state, .available)

        await update.installUpdateAndRestart()

        XCTAssertNotNil(update.lastError)
        XCTAssertEqual(update.phase, .idle)
        XCTAssertFalse(update.isApplyingUpdate)
        XCTAssertFalse(update.isDownloading, "UI must unlock after a failed install")
    }
}
