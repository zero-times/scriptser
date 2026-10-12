import Foundation
import ServiceManagement
import os.log

/// Centralized user preferences. Script commands are configured in each script's editor.
@MainActor
final class AppSettings: ObservableObject {
    private let logger = AppLogger.settings
    private let defaults: UserDefaults
    private let managesLoginItem: Bool
    private var syncingLoginItem = false

    private enum Keys {
        static let launchAtLogin = "launchAtLoginEnabled"
        static let outputBufferSize = "outputBufferSize"
    }

    @Published var lastError: String?

    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: AppLanguage.defaultsKey) }
    }

    @Published var launchAtLoginEnabled: Bool {
        didSet {
            defaults.set(launchAtLoginEnabled, forKey: Keys.launchAtLogin)
            if !syncingLoginItem { syncLaunchAtLogin() }
        }
    }

    @Published var outputBufferSize: Int {
        didSet { defaults.set(outputBufferSize, forKey: Keys.outputBufferSize) }
    }

    init(defaults: UserDefaults = .standard, managesLoginItem: Bool = true) {
        self.defaults = defaults
        self.managesLoginItem = managesLoginItem
        language = AppLanguage(rawValue: defaults.string(forKey: AppLanguage.defaultsKey) ?? "") ?? .system
        launchAtLoginEnabled = defaults.bool(forKey: Keys.launchAtLogin)
        let savedBufferSize = defaults.integer(forKey: Keys.outputBufferSize)
        outputBufferSize = savedBufferSize > 0 ? savedBufferSize : 10000
        syncLaunchAtLogin()
        logger.info("AppSettings initialized")
    }

    func resetToDefaults() {
        language = .system
        outputBufferSize = 10000
        logger.info("Settings reset to defaults")
    }

    private func syncLaunchAtLogin() {
        guard managesLoginItem else { return }
        syncingLoginItem = true
        defer { syncingLoginItem = false }
        let status = SMAppService.mainApp.status
        do {
            if launchAtLoginEnabled {
                if status != .enabled && status != .requiresApproval {
                    try SMAppService.mainApp.register()
                    logger.info("Registered for launch at login")
                }
            } else if status == .enabled || status == .requiresApproval {
                try SMAppService.mainApp.unregister()
                logger.info("Unregistered from launch at login")
            }
        } catch {
            logger.error("Failed to sync launch at login: \(error.localizedDescription)")
            lastError = L10n.format("Could not change login setting: %@", error.localizedDescription)
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        }
    }
}
