import Foundation
import ServiceManagement
import os.log

/// Quick action template for configurable script actions
struct QuickActionTemplate: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var commandPattern: String
    var actions: [QuickAction]

    struct QuickAction: Identifiable, Codable, Equatable {
        var id: UUID
        var label: String
        var subcommand: String

        init(id: UUID = UUID(), label: String, subcommand: String) {
            self.id = id
            self.label = label
            self.subcommand = subcommand
        }
    }

    static var defaults: [QuickActionTemplate] {
        [
            QuickActionTemplate(
                id: UUID(),
                name: "Docker run_app.sh",
                commandPattern: "run_app.sh",
                actions: [
                    QuickAction(label: "Status", subcommand: "status"),
                    QuickAction(label: "Stop", subcommand: "stop"),
                    QuickAction(label: "Restart", subcommand: "restart"),
                    QuickAction(label: "Logs", subcommand: "logs")
                ]
            )
        ]
    }
}

/// Centralized user preferences and configurable values
@MainActor
final class AppSettings: ObservableObject {
    private let logger = AppLogger.settings

    // User Defaults Keys
    private enum Keys {
        static let launchAtLogin = "launchAtLoginEnabled"
        static let dockerDirectory = "dockerDirectory"
        static let outputBufferSize = "outputBufferSize"
        static let quickActionTemplates = "quickActionTemplates"
    }

    @Published var launchAtLoginEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(launchAtLoginEnabled, forKey: Keys.launchAtLogin)
            syncLaunchAtLogin()
        }
    }

    @Published var dockerDirectory: String {
        didSet {
            UserDefaults.standard.set(dockerDirectory, forKey: Keys.dockerDirectory)
        }
    }

    @Published var outputBufferSize: Int {
        didSet {
            UserDefaults.standard.set(outputBufferSize, forKey: Keys.outputBufferSize)
        }
    }

    @Published var quickActionTemplates: [QuickActionTemplate] {
        didSet {
            saveQuickActionTemplates()
        }
    }

    init() {
        // Initialize all stored properties first
        self.launchAtLoginEnabled = UserDefaults.standard.bool(forKey: Keys.launchAtLogin)
        self.dockerDirectory = UserDefaults.standard.string(forKey: Keys.dockerDirectory)
            ?? Self.detectDefaultDockerDirectory()
            ?? ""
        let savedBufferSize = UserDefaults.standard.integer(forKey: Keys.outputBufferSize)
        self.outputBufferSize = savedBufferSize > 0 ? savedBufferSize : 10000
        self.quickActionTemplates = Self.loadQuickActionTemplates()

        syncLaunchAtLogin()
        logger.info("AppSettings initialized")
    }

    /// Reset all settings to defaults
    func resetToDefaults() {
        dockerDirectory = Self.detectDefaultDockerDirectory() ?? ""
        outputBufferSize = 10000
        quickActionTemplates = QuickActionTemplate.defaults
        logger.info("Settings reset to defaults")
    }

    private func syncLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        do {
            if launchAtLoginEnabled {
                if status != .enabled {
                    try SMAppService.mainApp.register()
                    logger.info("Registered for launch at login")
                }
            } else {
                if status == .enabled {
                    try SMAppService.mainApp.unregister()
                    logger.info("Unregistered from launch at login")
                }
            }
        } catch {
            logger.error("Failed to sync launch at login: \(error.localizedDescription)")
            launchAtLoginEnabled = (status == .enabled)
            UserDefaults.standard.set(launchAtLoginEnabled, forKey: Keys.launchAtLogin)
        }
    }

    private static func detectDefaultDockerDirectory() -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Documents/GitHub/ingoo-app/scripts/docker").path,
            home.appendingPathComponent("Documents/ingoo-app/scripts/docker").path,
            home.appendingPathComponent("docker").path
        ]
        return candidates.first { fileManager.fileExists(atPath: $0) }
    }

    private func saveQuickActionTemplates() {
        if let data = try? JSONEncoder().encode(quickActionTemplates) {
            UserDefaults.standard.set(data, forKey: Keys.quickActionTemplates)
        }
    }

    private static func loadQuickActionTemplates() -> [QuickActionTemplate] {
        guard let data = UserDefaults.standard.data(forKey: Keys.quickActionTemplates),
              let templates = try? JSONDecoder().decode([QuickActionTemplate].self, from: data) else {
            return QuickActionTemplate.defaults
        }
        return templates
    }
}
