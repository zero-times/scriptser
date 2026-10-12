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
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.responseCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor
final class UpdateCheckTests: XCTestCase {
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
}
