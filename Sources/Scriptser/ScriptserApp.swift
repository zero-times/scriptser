import AppKit
import SwiftUI

@main
struct ScriptserApp: App {
    @StateObject private var store = ScriptStore()

    init() {
        DispatchQueue.main.async {
            NSApp?.setActivationPolicy(.accessory)
        }
    }

    var body: some Scene {
        MenuBarExtra("Scriptser", systemImage: "terminal.fill") {
            ScriptMenuView()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            ScriptManagerView()
                .environmentObject(store)
        }
    }
}
