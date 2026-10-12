import AppKit
import CryptoKit
import Foundation

struct ReleaseVersion: Comparable, Equatable {
    let components: [Int]

    init?(_ tag: String) {
        var value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        // Stable GitHub Releases only. Build metadata does not change precedence.
        value = String(value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let browserDownloadURL: URL
        let size: Int64
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }

        var isTrustedPackage: Bool {
            let url = browserDownloadURL
            let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
            return url.scheme == "https" && url.host == "github.com"
                && url.path.hasPrefix("/zero-times/scriptser/releases/download/")
                && name == (name as NSString).lastPathComponent
                && ["dmg", "zip", "pkg"].contains(ext) && size > 0
                && !name.lowercased().contains("source")
        }
    }

    let tagName: String
    let htmlURL: URL
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case body, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    func package(for architecture: String) -> Asset? {
        let compatible = assets.filter { asset in
            guard asset.isTrustedPackage else { return false }
            let name = asset.name.lowercased()
            guard !["windows", "win32", "win64", "linux", "ubuntu", "android"].contains(where: name.contains) else { return false }
            let isARM = name.contains("arm64") || name.contains("aarch64") || name.contains("apple-silicon")
            let isIntel = name.contains("x86_64") || name.contains("x64") || name.contains("intel") || name.contains("amd64")
            let universal = name.contains("universal") || (isARM && isIntel)
            return universal || (!isARM && !isIntel) || (architecture == "arm64" ? isARM : isIntel)
        }
        // Prefer explicitly native/universal packages, then generic macOS packages.
        return compatible.sorted { lhs, rhs in
            func score(_ asset: Asset) -> Int {
                let name = asset.name.lowercased()
                return (name.contains(architecture) ? 4 : 0) + (name.contains("universal") ? 3 : 0)
                    + (name.hasSuffix(".dmg") ? 2 : 0)
            }
            let left = score(lhs), right = score(rhs)
            return left == right ? lhs.name < rhs.name : left > right
        }.first
    }
}

enum AppUpdateError: LocalizedError {
    case invalidRelease
    case http(Int)
    case rateLimited
    case invalidVersion
    case damagedDownload
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .invalidRelease: return L10n.text("The release does not contain a valid Scriptser update.")
        case .http(let code): return L10n.format("GitHub returned HTTP %d. Try again later.", code)
        case .rateLimited: return L10n.text("GitHub’s request limit has been reached. Try later or visit Releases.")
        case .invalidVersion: return L10n.text("The release version could not be compared with this app.")
        case .damagedDownload: return L10n.text("The downloaded update failed verification. Please download it again.")
        case .network(let error): return L10n.format("Update request failed: %@", error.localizedDescription)
        }
    }
}

@MainActor
final class AppUpdateManager: ObservableObject {
    enum State: Equatable { case idle, checking, current, available, noRelease, failed }
    static let releasesURL = URL(string: "https://github.com/zero-times/scriptser/releases")!
    private static let latestURL = URL(string: "https://api.github.com/repos/zero-times/scriptser/releases/latest")!
    private static let latestPageURL = URL(string: "https://github.com/zero-times/scriptser/releases/latest")!
    private let session: URLSession
    private let now: () -> Date
    private var nextCheckAllowedAt = Date.distantPast
    private var apiLimitedUntil = Date.distantPast
    private let download: (URLRequest) async throws -> (URL, URLResponse)
    private let logger = AppLogger.general
    let currentVersion: String

    @Published private(set) var state: State = .idle
    @Published private(set) var latestRelease: GitHubRelease?
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadedURL: URL?
    @Published private(set) var lastError: AppUpdateError?
    @Published private(set) var usesWebsiteFallback = false

    var package: GitHubRelease.Asset? {
        #if arch(arm64)
        return latestRelease?.package(for: "arm64")
        #else
        return latestRelease?.package(for: "x86_64")
        #endif
    }

    init(session: URLSession = .shared, currentVersion: String? = nil, now: @escaping () -> Date = Date.init,
         download: ((URLRequest) async throws -> (URL, URLResponse))? = nil) {
        self.session = session
        self.now = now
        self.download = download ?? { try await session.download(for: $0) }
        self.currentVersion = currentVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /// False means another surface already owns the in-flight check.
    @discardableResult
    func checkForUpdates() async -> Bool {
        guard state != .checking, !isDownloading else { return false }
        // Reuse the result briefly when the same check is requested from another surface.
        guard now() >= nextCheckAllowedAt else { return true }
        state = .checking
        latestRelease = nil
        downloadedURL = nil
        lastError = nil
        usesWebsiteFallback = false
        defer { nextCheckAllowedAt = now().addingTimeInterval(60) }
        do {
            let release: GitHubRelease
            if now() < apiLimitedUntil {
                release = try await releaseFromWebsite()
            } else {
                var request = URLRequest(url: Self.latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Scriptser/\(currentVersion)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw AppUpdateError.invalidRelease }
                if response.statusCode == 404 { state = .noRelease; return true }
                var limited = false
                if response.statusCode == 403 || response.statusCode == 429 {
                    let details = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let message = details?["message"] as? String ?? ""
                    if response.statusCode == 429 || response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                        || message.lowercased().contains("rate limit") { limited = true }
                }
                if limited {
                    let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
                    let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                    apiLimitedUntil = max(now().addingTimeInterval(60), reset.map(Date.init(timeIntervalSince1970:))
                        ?? now().addingTimeInterval(retry ?? 3600))
                    release = try await releaseFromWebsite()
                } else {
                    guard response.statusCode == 200 else { throw AppUpdateError.http(response.statusCode) }
                    release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                }
            }
            guard !release.draft, !release.prerelease,
                  release.htmlURL.scheme == "https", release.htmlURL.host == "github.com",
                  release.htmlURL.path.hasPrefix("/zero-times/scriptser/releases/tag/") else {
                throw AppUpdateError.invalidRelease
            }
            guard let installed = ReleaseVersion(currentVersion), let latest = ReleaseVersion(release.tagName) else {
                throw AppUpdateError.invalidVersion
            }
            latestRelease = release
            state = latest > installed ? .available : .current
            logger.info("Checked GitHub release: \(release.tagName)")
        } catch {
            lastError = (error as? AppUpdateError) ?? .network(error)
            state = .failed
            logger.error("Update check failed: \(error.localizedDescription)")
        }
        return true
    }

    /// GitHub's official /latest redirect identifies the stable release without API quota.
    /// Website responses have no trusted size/digest metadata: use Releases for installation.
    private func releaseFromWebsite() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.latestPageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("Scriptser/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AppUpdateError.invalidRelease }
        guard response.statusCode == 200 else {
            if response.statusCode == 403 || response.statusCode == 429 { throw AppUpdateError.rateLimited }
            throw AppUpdateError.http(response.statusCode)
        }
        guard let url = response.url, url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil,
              url.path.hasPrefix("/zero-times/scriptser/releases/tag/") else { throw AppUpdateError.invalidRelease }
        let tag = String(url.path.dropFirst("/zero-times/scriptser/releases/tag/".count))
        guard ReleaseVersion(tag) != nil else { throw AppUpdateError.invalidVersion }
        usesWebsiteFallback = true
        logger.info("Checked stable release using GitHub website: \(tag)")
        return GitHubRelease(tagName: tag, htmlURL: url, body: nil, draft: false, prerelease: false, assets: [])
    }

    /// Downloads only a published release package; installation is completed in Finder/the installer.
    func downloadUpdate(to destination: URL) async {
        guard state == .available, let asset = package, !isDownloading else { return }
        isDownloading = true
        downloadedURL = nil
        lastError = nil
        defer { isDownloading = false }
        do {
            let request = URLRequest(url: asset.browserDownloadURL, timeoutInterval: 120)
            let (temporaryURL, response) = try await download(request)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw AppUpdateError.invalidRelease
            }
            // Save to the path explicitly selected in the native save dialog.
            let accessed = destination.startAccessingSecurityScopedResource()
            defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
            try await Task.detached {
                try Self.verifyDownload(at: temporaryURL, asset: asset)
                let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
                try data.write(to: destination, options: .atomic)
            }.value
            downloadedURL = destination
            logger.info("Saved update package: \(asset.name)")
        } catch {
            lastError = (error as? AppUpdateError) ?? .network(error)
            logger.error("Update download failed: \(error.localizedDescription)")
        }
    }

    nonisolated static func verifyDownload(at url: URL, asset: GitHubRelease.Asset) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == asset.size else { throw AppUpdateError.damagedDownload }
        if let digest = asset.digest {
            guard digest.hasPrefix("sha256:") else { throw AppUpdateError.damagedDownload }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hasher = SHA256()
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hasher.update(data: data) }
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == String(digest.dropFirst(7)).lowercased() else { throw AppUpdateError.damagedDownload }
        }
    }
}
