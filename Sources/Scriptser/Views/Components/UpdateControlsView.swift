import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct UpdateControlsView: View {
    @EnvironmentObject private var store: ScriptStore
    @State private var showingUpdate = false
    @State private var checkError: ScriptStoreError?

    private var status: String {
        switch store.updateManager.state {
        case .idle: return L10n.format("Version %@", store.updateManager.currentVersion)
        case .checking: return L10n.text("Checking for updates...")
        case .current: return L10n.text("You’re up to date.")
        case .available: return L10n.format("Version %@ is available", store.updateManager.latestRelease?.tagName ?? "")
        case .noRelease: return L10n.text("No releases published yet.")
        case .failed: return L10n.text("Update check failed.")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if store.updateManager.state == .checking { ProgressView().controlSize(.small) }
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            if store.updateManager.state == .available {
                Button(L10n.text("View Update")) { showingUpdate = true }
            } else {
                Button(L10n.text("Check for Updates...")) {
                    Task {
                        guard await store.updateManager.checkForUpdates() else { return }
                        if let error = store.updateManager.lastError { checkError = .updateError(error) }
                        if store.updateManager.state == .available { showingUpdate = true }
                    }
                }
                .disabled(store.updateManager.state == .checking || store.updateManager.isDownloading)
            }
            Button { NSWorkspace.shared.open(AppUpdateManager.releasesURL) } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .help(L10n.text("Visit Releases"))
            .accessibilityLabel(L10n.text("Visit Releases"))
        }
        .sheet(isPresented: $showingUpdate) { UpdateDetailsView() }
        .errorAlert($checkError)
    }
}

struct UpdateDetailsView: View {
    @EnvironmentObject private var store: ScriptStore
    @Environment(\.dismiss) private var dismiss
    @State private var downloadError: ScriptStoreError?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.text("Scriptser Update"), systemImage: "arrow.down.circle")
                .font(.title2.weight(.semibold))
            if let release = store.updateManager.latestRelease {
                Text(L10n.format("Version %@ is available", release.tagName)).font(.headline)
                Text(L10n.format("Installed version: %@", store.updateManager.currentVersion))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(release.body?.isEmpty == false ? release.body! : L10n.text("No release notes provided."))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(minHeight: 120, maxHeight: 220)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                if store.updateManager.canApplyUpdateInPlace {
                    Text(L10n.text("The update downloads, verifies, replaces the app, and restarts Scriptser automatically. Scripts and preferences are kept."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L10n.text("Open the downloaded package, quit Scriptser, and replace the app in Applications. Your scripts and preferences are kept."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if store.updateManager.package == nil {
                    Text(L10n.text(store.updateManager.usesWebsiteFallback
                        ? "Version checked via the release page. Visit Releases to download the installer."
                        : "No compatible macOS package is attached. Visit Releases for installation options."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            progressSection
            if let url = store.updateManager.downloadedURL {
                Label(L10n.text("Update downloaded. Open the package to install."), systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Button(L10n.text("Open Download")) { NSWorkspace.shared.open(url) }
                Button(L10n.text("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            HStack {
                Button(L10n.text("Visit Releases")) { NSWorkspace.shared.open(store.updateManager.latestRelease?.htmlURL ?? AppUpdateManager.releasesURL) }
                Spacer()
                Button(L10n.text("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.updateManager.isDownloading || store.updateManager.isApplyingUpdate)
                if store.updateManager.downloadedURL == nil, store.updateManager.package != nil {
                    if store.updateManager.canApplyUpdateInPlace {
                        Button(L10n.text("Install and Restart")) { installUpdate() }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.updateManager.isDownloading || store.updateManager.isApplyingUpdate)
                    } else {
                        Button(L10n.text("Download Update...")) { chooseDestination() }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.updateManager.isDownloading)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 580)
        .interactiveDismissDisabled(store.updateManager.isDownloading || store.updateManager.isApplyingUpdate)
        .errorAlert($downloadError)
    }

    @ViewBuilder
    private var progressSection: some View {
        switch store.updateManager.phase {
        case .downloading:
            if let progress = store.updateManager.downloadProgress {
                ProgressView(value: progress) {
                    Text(L10n.text("Downloading update..."))
                } currentValueLabel: {
                    Text("\(Int((progress * 100).rounded()))%")
                }
            } else {
                ProgressView(L10n.text("Downloading update..."))
            }
        case .verifying:
            ProgressView(L10n.text("Verifying update..."))
        case .preparing:
            ProgressView(L10n.text("Preparing update..."))
        case .installing, .restarting:
            ProgressView(L10n.text("Installing update..."))
        case .idle, .checking:
            EmptyView()
        }
    }

    private func installUpdate() {
        Task {
            await store.updateManager.installUpdateAndRestart()
            if let error = store.updateManager.lastError { downloadError = .updateError(error) }
        }
    }

    private func chooseDestination() {
        guard let asset = store.updateManager.package else { return }
        let panel = NSSavePanel()
        panel.title = L10n.text("Download Update...")
        panel.nameFieldStringValue = asset.name
        if let type = UTType(filenameExtension: (asset.name as NSString).pathExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await store.updateManager.downloadUpdate(to: url)
                if let error = store.updateManager.lastError { downloadError = .updateError(error) }
            }
        }
    }
}
