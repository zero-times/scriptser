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
    case unsupportedPackage
    case mountFailed
    case missingApplication
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRelease: return L10n.text("The release does not contain a valid Scriptser update.")
        case .http(let code): return L10n.format("GitHub returned HTTP %d. Try again later.", code)
        case .rateLimited: return L10n.text("GitHub’s request limit has been reached. Try later or visit Releases.")
        case .invalidVersion: return L10n.text("The release version could not be compared with this app.")
        case .damagedDownload: return L10n.text("The downloaded update failed verification. Please download it again.")
        case .network(let error): return L10n.format("Update request failed: %@", error.localizedDescription)
        case .unsupportedPackage: return L10n.text("Automatic installation supports DMG or ZIP update packages.")
        case .mountFailed: return L10n.text("The update package could not be mounted.")
        case .missingApplication: return L10n.text("The update package does not contain the Scriptser app.")
        case .installFailed(let detail): return L10n.format("Update installation failed: %@", detail)
        }
    }
}

@MainActor
final class AppUpdateManager: ObservableObject {
    enum State: Equatable { case idle, checking, current, available, noRelease, failed }
    enum UpdatePhase: Equatable { case idle, checking, downloading, verifying, preparing, installing, restarting }

    static let releasesURL = URL(string: "https://github.com/zero-times/scriptser/releases")!
    private static let latestURL = URL(string: "https://api.github.com/repos/zero-times/scriptser/releases/latest")!
    private static let latestPageURL = URL(string: "https://github.com/zero-times/scriptser/releases/latest")!
    private let session: URLSession
    private let now: () -> Date
    private var nextCheckAllowedAt = Date.distantPast
    private var apiLimitedUntil = Date.distantPast
    private let downloadOverride: ((URLRequest) async throws -> (URL, URLResponse))?
    private let logger = AppLogger.general
    let currentVersion: String

    @Published private(set) var state: State = .idle
    @Published private(set) var phase: UpdatePhase = .idle
    @Published private(set) var latestRelease: GitHubRelease?
    @Published private(set) var isDownloading = false
    @Published private(set) var isApplyingUpdate = false
    @Published private(set) var downloadProgress: Double?
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

    /// The bundle this running app can replace in place. DEV builds use a separate
    /// bundle identifier and are excluded so the release updater never replaces them.
    var canApplyUpdateInPlace: Bool {
        Bundle.main.bundleIdentifier == "com.ingoo.scriptser" && installedAppURL.pathExtension == "app"
    }

    var installedAppURL: URL {
        let bundle = Bundle.main.bundleURL
        if Bundle.main.bundleIdentifier == "com.ingoo.scriptser", bundle.pathExtension == "app" {
            return bundle
        }
        return URL(fileURLWithPath: "/Applications/Scriptser.app")
    }

    init(session: URLSession = .shared, currentVersion: String? = nil, now: @escaping () -> Date = Date.init,
         download: ((URLRequest) async throws -> (URL, URLResponse))? = nil) {
        self.session = session
        self.now = now
        self.downloadOverride = download
        self.currentVersion = currentVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0"
    }

    /// False means another surface already owns the in-flight check.
    @discardableResult
    func checkForUpdates() async -> Bool {
        guard state != .checking, !isDownloading, !isApplyingUpdate else { return false }
        // Reuse the result briefly when the same check is requested from another surface.
        guard now() >= nextCheckAllowedAt else { return true }
        state = .checking
        phase = .checking
        latestRelease = nil
        downloadedURL = nil
        lastError = nil
        usesWebsiteFallback = false
        defer {
            nextCheckAllowedAt = now().addingTimeInterval(60)
            phase = .idle
            downloadProgress = nil
        }
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

    /// Saves a verified package through the native save dialog. Kept as the manual fallback
    /// for builds that cannot replace themselves in place.
    func downloadUpdate(to destination: URL) async {
        guard state == .available, let asset = package, !isDownloading, !isApplyingUpdate else { return }
        isDownloading = true
        downloadedURL = nil
        lastError = nil
        phase = .downloading
        downloadProgress = nil
        defer {
            isDownloading = false
            phase = .idle
            if downloadedURL == nil { downloadProgress = nil }
        }
        do {
            let temporaryURL = try await fetchVerifiedPackage(asset)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            // Save to the path explicitly selected in the native save dialog.
            let accessed = destination.startAccessingSecurityScopedResource()
            defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
            try await Task.detached {
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

    /// Downloads and verifies the release package, stages the replacement app bundle,
    /// then swaps it in and relaunches Scriptser after this process exits.
    func installUpdateAndRestart() async {
        guard canApplyUpdateInPlace, state == .available, let asset = package, !isDownloading, !isApplyingUpdate else { return }
        isApplyingUpdate = true
        lastError = nil
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory.appendingPathComponent("Scriptser-Update-\(UUID().uuidString)")
        defer {
            isApplyingUpdate = false
            if phase != .restarting {
                phase = .idle
                downloadProgress = nil
                try? fileManager.removeItem(at: workDirectory)
            }
        }
        do {
            isDownloading = true
            let temporaryURL = try await fetchVerifiedPackage(asset)
            isDownloading = false
            defer { try? fileManager.removeItem(at: temporaryURL) }

            try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            let packageURL = workDirectory.appendingPathComponent(asset.name)
            try fileManager.moveItem(at: temporaryURL, to: packageURL)

            phase = .preparing
            let appName = installedAppURL.lastPathComponent
            let stagedAppURL = try await Task.detached {
                try Self.prepareStagedApp(packageURL: packageURL,
                                          appName: appName,
                                          stagingDirectory: workDirectory)
            }.value
            guard stagedAppURL.pathExtension == "app" else { throw AppUpdateError.missingApplication }

            phase = .installing
            try launchRestartHelper(stagedAppURL: stagedAppURL, targetURL: installedAppURL, workDirectory: workDirectory)
            phase = .restarting
            logger.info("Update staged; restarting Scriptser")
            NSApp.terminate(nil)
        } catch {
            lastError = (error as? AppUpdateError) ?? .network(error)
            logger.error("Automatic update failed: \(error.localizedDescription)")
        }
    }

    private func fetchVerifiedPackage(_ asset: GitHubRelease.Asset) async throws -> URL {
        phase = .downloading
        downloadProgress = nil
        let request = URLRequest(url: asset.browserDownloadURL, timeoutInterval: 120)
        var temporaryURL: URL?
        var response: URLResponse?
        do {
            if let downloadOverride {
                (temporaryURL, response) = try await downloadOverride(request)
            } else {
                (temporaryURL, response) = try await downloadWithProgress(request)
            }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let temporaryURL else {
                throw AppUpdateError.invalidRelease
            }
            phase = .verifying
            try await Task.detached {
                try Self.verifyDownload(at: temporaryURL, asset: asset)
            }.value
            return temporaryURL
        } catch {
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            throw error
        }
    }

    /// Streams the package so the UI can show real download progress without a delegate object.
    private func downloadWithProgress(_ request: URLRequest) async throws -> (URL, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        let expected = (response as? HTTPURLResponse)?.expectedContentLength ?? -1
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scriptser-update-\(UUID().uuidString).download")
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        var completed = false
        defer {
            try? handle.close()
            if !completed { try? FileManager.default.removeItem(at: temporaryURL) }
        }
        var received: Int64 = 0
        var buffer = Data()
        for try await chunk in bytes {
            buffer.append(chunk)
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            if expected > 0 {
                let value = min(1, Double(received) / Double(expected))
                if abs((downloadProgress ?? 0) - value) >= 0.001 {
                    downloadProgress = value
                }
            }
        }
        downloadProgress = 1
        completed = true
        return (temporaryURL, response)
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

    nonisolated private static func prepareStagedApp(packageURL: URL, appName: String, stagingDirectory: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let stagedAppURL = stagingDirectory.appendingPathComponent(appName)
        switch packageURL.pathExtension.lowercased() {
        case "dmg":
            let mountPoint = try mountDMG(at: packageURL)
            defer { try? detachDMG(mountPoint) }
            guard let source = locateApp(in: mountPoint, name: appName) else { throw AppUpdateError.missingApplication }
            try runTool("/usr/bin/ditto", [source.path, stagedAppURL.path])
        case "zip":
            let extraction = stagingDirectory.appendingPathComponent("extracted")
            try fileManager.createDirectory(at: extraction, withIntermediateDirectories: true)
            try runTool("/usr/bin/ditto", ["-x", "-k", packageURL.path, extraction.path])
            guard let source = locateApp(in: extraction, name: appName) else { throw AppUpdateError.missingApplication }
            try fileManager.moveItem(at: source, to: stagedAppURL)
            try? fileManager.removeItem(at: extraction)
        default:
            throw AppUpdateError.unsupportedPackage
        }
        guard fileManager.fileExists(atPath: stagedAppURL.path) else { throw AppUpdateError.missingApplication }
        return stagedAppURL
    }

    nonisolated private static func locateApp(in directory: URL, name: String) -> URL? {
        let fileManager = FileManager.default
        let direct = directory.appendingPathComponent(name)
        if fileManager.fileExists(atPath: direct.path) { return direct }
        guard let enumerator = fileManager.enumerator(at: directory,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return nil }
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "app" else { continue }
            if url.lastPathComponent == name { return url }
        }
        return nil
    }

    nonisolated private static func mountDMG(at url: URL) throws -> URL {
        let output = try runToolCapturingOutput("/usr/bin/hdiutil",
                                                ["attach", url.path, "-nobrowse", "-readonly", "-plist"])
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(output.utf8),
                                                                      options: [],
                                                                      format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw AppUpdateError.mountFailed
        }
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String, !mountPoint.isEmpty {
                return URL(fileURLWithPath: mountPoint)
            }
        }
        throw AppUpdateError.mountFailed
    }

    nonisolated private static func detachDMG(_ mountPoint: URL) throws {
        try runTool("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
    }

    nonisolated private static func runTool(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppUpdateError.installFailed("\(URL(fileURLWithPath: executable).lastPathComponent) exited with code \(process.terminationStatus)")
        }
    }

    nonisolated private static func runToolCapturingOutput(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppUpdateError.installFailed("\(URL(fileURLWithPath: executable).lastPathComponent) exited with code \(process.terminationStatus)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func launchRestartHelper(stagedAppURL: URL, targetURL: URL, workDirectory: URL) throws {
        let scriptURL = workDirectory.appendingPathComponent("install-update.sh")
        let logURL = workDirectory.appendingPathComponent("install-update.log")
        try Self.restartScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path, logURL.path, targetURL.path, stagedAppURL.path,
                             workDirectory.path, String(ProcessInfo.processInfo.processIdentifier)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static let restartScript = """
    #!/bin/zsh
    set -u
    log="$1"
    target="$2"
    staged="$3"
    work="$4"
    parent_pid="$5"
    print_log() {
        /usr/bin/printf '%s %s\\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$log"
    }
    {
        print_log "Waiting for Scriptser (pid $parent_pid) to exit"
        i=0
        while (( i < 600 )); do
            if ! /bin/kill -0 "$parent_pid" 2>/dev/null; then
                break
            fi
            /bin/sleep 0.2
            (( i += 1 ))
        done
        if /bin/kill -0 "$parent_pid" 2>/dev/null; then
            print_log "Timed out waiting for Scriptser to exit"
            exit 1
        fi
        if [[ -e "$target" ]]; then
            /bin/rm -rf -- "$target" || { print_log "Failed to remove $target"; exit 1; }
        fi
        /bin/mv -- "$staged" "$target" || { print_log "Failed to install $target"; exit 1; }
        print_log "Relaunching Scriptser"
        /usr/bin/open -- "$target" || { print_log "Failed to relaunch $target"; exit 1; }
        print_log "Update complete"
        /bin/rm -rf -- "$work"
    } >> "$log" 2>&1
    """
}
