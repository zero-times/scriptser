# Scriptser

A lightweight macOS 13+ menu bar app for managing and running local shell scripts. Scriptser uses only Apple frameworks and requires no backend for script execution.

## Build and run

```sh
swift build
.build/debug/Scriptser
```

Or open `Scriptser.xcodeproj` and run the Scriptser scheme in Xcode. The application stays in the menu bar; open **Manager** to manage scripts.

## Scripts

- Add a name, any shell command or multiline script, and an optional working directory. Commands run with `/bin/zsh -ilc`, loading your login and interactive shell environment.
- **Enabled** controls whether a script can run, including **Run All**.
- **Run when Scriptser launches** automatically runs an enabled script once when the app starts. This is independent of **Launch at Login**, which starts the app when you sign in to your Mac.
- On restart, Scriptser restores tracked processes that are still running before starting automatic scripts, avoiding duplicate runs. Old configurations default to automatic execution off. Changing the switch or importing scripts applies on the next app launch.
- Choose **Add Custom Command…** in Manager or the menu bar to save any command or multiline script. Commands are fully custom. The former Docker Quick Commands and pattern-based quick actions have been removed; saved script commands remain intact.
- Use **Output** for live output, copying, clearing, and automatic scrolling. Output buffers are in memory and do not survive app restarts.

## Language and navigation

Choose **Follow System**, **简体中文**, or **English** in Manager. Language changes apply immediately to the menu, editor, output viewer, and app error messages, and are remembered across launches. Commands, script names, and raw shell output remain as entered.

Manager has **All Scripts**, **Running**, and **At Launch** filters. Search matches names, commands, directories, and tags. The menu bar shows script names and live status, and scrolls when there are many scripts. Manager, the application menu, and DEV Dock activation reuse a single management window; settings are part of that window.

Shortcuts: ⌘N to add a script, ⌘F to search, ⌘S to save in the editor, ⇧⌘R to run all, ⇧⌘. to stop all, and Escape to close a dialog.

## AI Skill

Open **AI Skill** (⇧⌘K) in Manager to select a skills directory and generate a ready-to-load `scriptser-control` folder containing `SKILL.md` and `references/ui.md`. The default is `~/.codex/skills`, or `$CODEX_HOME/skills` when that variable is available to the app. The selected directory is remembered. Generation also works in custom assistant directories.

The dialog includes a preview, installation steps, **Open Skill Folder**, and **Copy Adding Prompt** with the absolute entrypoint path. In Codex, start a new chat and invoke `$scriptser-control`, or paste the adding prompt to load the Skill by path. The Skill covers all interface operations, including process termination and app updates. It requires an assistant with macOS UI automation and Accessibility access; it supplies guidance without installing an automation tool or introducing a backend.

Generating again replaces the two bundled instruction files while preserving additional files. Unrelated Skills and symbolic links at the destination are rejected. DEV generates `scriptser-dev-control` with its own app target, so it can coexist with the production Skill. Generated targets use the current app installation path; regenerate after moving the app or use its new location.

## Process details and application icon

Running script rows in Manager and the menu bar, and their Output viewer, show the tracked process **PID**. **Stop** sends normal termination. **End Process** confirms the script name and PID, then sends `SIGKILL` to that tracked process. The action rejects a confirmation for an old PID after a script restarts. It affects the tracked shell process, not an entire process tree. PID is cleared when execution ends, and recovered running scripts display their persisted PID.

The bundled macOS app icon is shared by the shipping and DEV app. Its reproducible AppKit source is `tools/generate-app-icon.swift`; run the commands in that file to regenerate `Resources/AppIcon.icns`.

## Updates

**Check for Updates…** is available in Manager and the menu bar. It contacts the public GitHub API for the latest stable release from [zero-times/scriptser Releases](https://github.com/zero-times/scriptser/releases). Concurrent checks share one request, and checks within 60 seconds reuse the result. If GitHub returns an API quota error, Scriptser checks the official latest-release webpage and avoids retrying the API until its quota reset. In this fallback, package metadata is unavailable, so use **Visit Releases** to download the installer. Errors are presented only at the initiating update control. Checks run only when requested; drafts and prereleases are excluded, and equal or older versions are never offered as updates.

For a newer release, view the release notes and choose **Install and Restart**. Scriptser downloads the package with live progress, verifies its size and GitHub's SHA-256 digest when provided, mounts the `.dmg` or extracts the `.zip`, stages the replacement app, then swaps the bundle and relaunches automatically after quitting. Scripts and preferences stay in their existing locations. Automatic in-place installation applies to the production app; the DEV build and `.pkg` packages keep the manual fallback, where **Download Update…** saves the verified package and **Open Download** opens it for a manual replacement in Applications.

Publish stable tags such as `v1.0.1` and attach packages named, for example, `Scriptser-arm64.dmg`, `Scriptser-x86_64.dmg`, or `Scriptser-universal.zip`. GitHub's generated source-code archives are not app updates. If no compatible package is available, the update view links to Releases; before the first release, the check reports that no releases are published.

## Configuration

Scripts are saved to:

```text
~/Library/Application Support/Scriptser/config.json
```

Use **Import/Export** to transfer JSON configurations. Imported and exported scripts include the automatic execution switch. User preferences and tracked process IDs are stored in UserDefaults.

## Verification

```sh
swift test
xcodebuild -project Scriptser.xcodeproj -scheme Scriptser -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Tests use temporary configuration files and isolated preferences to cover configuration compatibility, language resources, automatic execution, process recovery, duplicate prevention, failure handling, GitHub version checks, package selection, and verified update downloads.

macOS Login Items registration requires a properly bundled application. If macOS requests approval, enable Scriptser in System Settings → General → Login Items. Validate login registration in the signed application on the target Mac.

## Local DEV app

Run `zsh tools/build-dev.sh` to build a DEV app from the same entry point and views as the shipping app. DEV uses `~/Library/Application Support/Scriptser-DEV/config.json`, keeps its own preferences, and does not register a login item. Its single manager window is also reachable from the Dock. The build is ad-hoc signed for local verification.
