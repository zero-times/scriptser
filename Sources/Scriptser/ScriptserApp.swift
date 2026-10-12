import AppKit
import SwiftUI

@main
struct ScriptserApp: App {
    static let managerWindowID = "script-manager"
    @Environment(\.openWindow) private var openWindow
    @StateObject private var store: ScriptStore

    private static var isDevelopmentApp: Bool {
        Bundle.main.bundleIdentifier == "com.scriptser.scr1.preview"
    }

    private var appName: String { Self.isDevelopmentApp ? "Scriptser DEV" : "Scriptser" }

    init() {
        if Self.isDevelopmentApp {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let config = support.appendingPathComponent("Scriptser-DEV/config.json")
            // Repository errors are surfaced by ScriptStore rather than crashing the DEV app.
            _store = StateObject(wrappedValue: ScriptStore(configURL: config, settings: AppSettings(managesLoginItem: false)))
        } else {
            _store = StateObject(wrappedValue: ScriptStore())
        }
        DispatchQueue.main.async {
            NSApp?.setActivationPolicy(Self.isDevelopmentApp ? .regular : .accessory)
        }
    }

    var body: some Scene {
        // Window, unlike WindowGroup, reuses the same manager for every entry point.
        Window(appName, id: Self.managerWindowID) {
            ScriptManagerView()
                .environmentObject(store)
                .environment(\.locale, store.settings.language.locale)
        }
        .defaultSize(width: 900, height: 640)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L10n.text("Manager")) {
                    openWindow(id: Self.managerWindowID)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        MenuBarExtra(appName, systemImage: "terminal.fill") {
            ScriptMenuView()
                .environmentObject(store)
                .environment(\.locale, store.settings.language.locale)
        }
        .menuBarExtraStyle(.window)
    }
}
