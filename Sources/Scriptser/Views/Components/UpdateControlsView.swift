import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct UpdateControlsView: View {
    @EnvironmentObject private var store: ScriptStore
    @State private var showingUpdate = false

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
                        await store.updateManager.checkForUpdates()
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
    }
}

struct UpdateDetailsView: View {
    @EnvironmentObject private var store: ScriptStore
    @Environment(\.dismiss) private var dismiss

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
                Text(L10n.text("Open the downloaded package, quit Scriptser, and replace the app in Applications. Your scripts and preferences are kept."))
                    .font(.caption).foregroundStyle(.secondary)
                if store.updateManager.package == nil {
                    Text(L10n.text("No compatible macOS package is attached. Visit Releases for installation options."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if store.updateManager.isDownloading {
                ProgressView(L10n.text("Downloading and verifying update..."))
            }
            if let url = store.updateManager.downloadedURL {
                Label(L10n.text("Update downloaded. Open the package to install."), systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Button(L10n.text("Open Download")) { NSWorkspace.shared.open(url) }
                Button(L10n.text("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            HStack {
                Button(L10n.text("Visit Releases")) { NSWorkspace.shared.open(AppUpdateManager.releasesURL) }
                Spacer()
                Button(L10n.text("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.updateManager.isDownloading)
                if store.updateManager.downloadedURL == nil, store.updateManager.package != nil {
                    Button(L10n.text("Download Update...")) { chooseDestination() }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.updateManager.isDownloading)
                }
            }
        }
        .padding(20)
        .frame(width: 580)
        .interactiveDismissDisabled(store.updateManager.isDownloading)
        .errorAlert($store.lastError)
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
            Task { await store.updateManager.downloadUpdate(to: url) }
        }
    }
}
