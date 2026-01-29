# AGENTS.md - AI Agent Guidelines for Scriptser

This document provides context and guidelines for AI agents working on the Scriptser codebase.

## Project Overview

**Scriptser** is a macOS menu bar application for managing and executing shell scripts. It runs as a lightweight accessory app with persistent process tracking across app restarts.

- **Platform**: macOS 13+
- **Tech Stack**: Swift 5.9+, SwiftUI
- **Build System**: Swift Package Manager (SPM)
- **Architecture**: MVVM with separated concerns

## Project Structure

```
Sources/Scriptser/
├── ScriptModels.swift           # Data models (ScriptEntry, RunStatus, ScriptRunState)
├── ScriptserApp.swift           # App entry point, MenuBarExtra + Settings scenes
├── Store/
│   ├── AppSettings.swift        # User preferences (launch at login, docker dir, templates)
│   ├── ProcessManager.swift     # Process lifecycle with actor-based thread safety
│   ├── ScriptRepository.swift   # JSON persistence layer
│   └── ScriptStore.swift        # Thin coordinator, combines all store components
├── Utilities/
│   └── Logger.swift             # os.log wrapper (AppLogger enum)
└── Views/
    ├── Components/
    │   └── StatusBadge.swift    # Reusable status indicator
    ├── OutputViewerView.swift   # Script output display panel
    ├── ScriptEditorView.swift   # Create/edit script dialog
    ├── ScriptManagerView.swift  # Main settings window
    └── ScriptMenuView.swift     # Menu bar dropdown
```

## Architecture Patterns

### Store Layer (MVVM)

```
ScriptStore (Coordinator)
├── ScriptRepository    → JSON persistence (load/save/import/export)
├── ProcessManager      → Process lifecycle (run/stop/output)
└── AppSettings         → User preferences
```

### Thread Safety

- **ProcessState**: Swift `actor` that protects mutable state (processes, PIDs, output buffers)
- **@MainActor**: All store classes and views run on main thread
- **async/await**: Used for process operations and output retrieval

### Key Types

| Type | Purpose |
|------|---------|
| `ScriptEntry` | Script definition (id, name, command, workingDirectory, isEnabled, tags, timestamps) |
| `ScriptRunState` | Execution state (status, message, startedAt, endedAt, exitCode) |
| `RunStatus` | Enum: idle, running, success, failed, stopped |
| `QuickActionTemplate` | Configurable quick action buttons |

## Code Conventions

### Swift Style

- Use `@MainActor` for UI-related classes
- Use `actor` for shared mutable state
- Prefer `async/await` over callbacks
- Use `os.log` via `AppLogger` for logging
- Error types conform to `LocalizedError`

### Naming

- Views: `*View.swift`
- Store components: Located in `Store/` directory
- Reusable components: Located in `Views/Components/`

### Error Handling

```swift
enum RepositoryError: LocalizedError {
    case loadFailed(underlying: Error)
    case saveFailed(underlying: Error)
    // ...
}

enum ProcessError: LocalizedError {
    case scriptDisabled
    case emptyCommand
    case alreadyRunning
    case startFailed(underlying: Error)
}
```

## Key Implementation Details

### Process Management

1. Scripts run via `/bin/zsh -lc "<command>"`
2. Output captured via `Pipe` and stored in actor-protected buffer
3. Process PIDs persisted to `UserDefaults` for recovery across app restarts
4. Termination handled via `terminationHandler` closure

### Persistence

- **Config file**: `~/Library/Application Support/Scriptser/config.json`
- **Run states**: `UserDefaults` (key: `scriptserRunState`)
- **Settings**: `UserDefaults` (various keys in `AppSettings.Keys`)

### Data Model Compatibility

`ScriptEntry` uses custom `Decodable` init for backward compatibility:

```swift
init(from decoder: Decoder) throws {
    // New fields use decodeIfPresent with defaults
    tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
}
```

## Common Tasks

### Adding a New Script Property

1. Add property to `ScriptEntry` in `ScriptModels.swift`
2. Add to `init(from decoder:)` with `decodeIfPresent` and default value
3. Add to manual `init` parameters
4. Update `ScriptEditorView` UI if user-editable

### Adding a New Store Feature

1. Determine which component owns it (Repository, ProcessManager, or Settings)
2. Implement in appropriate component
3. Expose through `ScriptStore` coordinator if needed
4. Add error case to relevant error enum

### Adding a New View

1. Create file in `Views/` (or `Views/Components/` if reusable)
2. Use `@EnvironmentObject private var store: ScriptStore`
3. Access settings via `store.settings`
4. Access process state via `store.processManager.runStates`

## Testing Guidelines

### Manual Testing Checklist

- [ ] Add/Edit/Delete scripts
- [ ] Run/Stop individual scripts
- [ ] Run All / Stop All
- [ ] View script output (live updates)
- [ ] Search/filter scripts
- [ ] Import/Export scripts
- [ ] Launch at Login toggle
- [ ] App restart with running scripts (process recovery)
- [ ] Menu bar dropdown functionality

### Error Scenarios

- Delete config file and restart app
- Run script with invalid command
- Run script with non-existent working directory
- Import malformed JSON file

## Dependencies

**None** - Uses only Apple frameworks:
- Foundation
- AppKit
- SwiftUI
- ServiceManagement (for launch at login)
- UniformTypeIdentifiers (for file export)
- os.log (for logging)

## Build & Run

```bash
# Build
swift build

# Run
.build/debug/Scriptser

# Or open in Xcode
open Scriptser.xcodeproj
```

## Important Notes for AI Agents

1. **@MainActor**: Most classes are `@MainActor`. Don't create background thread issues.

2. **Actor isolation**: `ProcessState` is an actor. Access via `await`.

3. **Backward compatibility**: When modifying `ScriptEntry`, always use `decodeIfPresent` with defaults.

4. **No external dependencies**: Keep it that way unless absolutely necessary.

5. **macOS 13+ target**: Can use modern SwiftUI features, but check availability for macOS 14+ APIs (like `SettingsLink`).

6. **Menu bar app**: App uses `.accessory` activation policy - no dock icon.

7. **Logging**: Use `AppLogger.category.info/error/debug()` not `print()`.

8. **Error handling**: Errors should be user-visible via `store.lastError` and the error alert modifier.
