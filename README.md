# Scriptser

A lightweight macOS 13+ menu bar app for managing and running local shell scripts. Scriptser uses only Apple frameworks and requires no backend for script execution.

## Build and run

```sh
swift build
.build/debug/Scriptser
```

Or open `Scriptser.xcodeproj` and run the Scriptser scheme in Xcode. The application stays in the menu bar; open **Manager** to manage scripts.

## Scripts

- Add a name, optional notes, any shell command or multiline script, and an optional working directory. Commands run with `/bin/zsh -ilc`, loading your login and interactive shell environment.
- **Enabled** controls whether a script can run, including **Run All**.
- **Run when Scriptser launches** automatically runs an enabled script once when the app starts. This is independent of **Launch at Login**, which starts the app when you sign in to your Mac.
- On restart, Scriptser restores tracked processes that are still running before starting automatic scripts, avoiding duplicate runs. Old configurations default to automatic execution off. Changing the switch or importing scripts applies on the next app launch.
- Choose **Add Custom Command…** in Manager or the menu bar to save any command or multiline script. Commands are fully custom. The former Docker Quick Commands and pattern-based quick actions have been removed; saved script commands remain intact.
- Use **Output** for live output, copying, clearing, and automatic scrolling. Output buffers are in memory and do not survive app restarts.

## Language and navigation

Choose **Follow System**, **简体中文**, or **English** in Manager. Language changes apply immediately to the menu, editor, output viewer, and app error messages, and are remembered across launches. Commands, script names, and raw shell output remain as entered.

Manager has **All Scripts**, **Running**, and **At Launch** filters. Search matches names, notes, commands, directories, and tags. Both lists show only the name, a one-line note (when provided), and a status/action button by default. Click a script’s name or choose **Show Details** to expand its full notes, command, directory, tags, last run, duration, and process information. The **More Actions** menu provides editing, execution, and, in Manager, output and deletion. The menu bar scrolls when needed, including with expanded details.

The status button shows **Run**, **Running · Stop**, **Success · Run**, **Failed · Retry**, or **Stopped · Run**. Click it to run, retry, or stop the target script; disabled scripts cannot start, but a running disabled script can still be stopped. Status includes text and an action symbol as well as color. Old configurations without notes continue to load; notes are saved and included in JSON import/export. Manager, the application menu, and DEV Dock activation reuse a single management window; settings are part of that window.

Shortcuts: ⌘N to add a script, ⌘F to search, ⌘S to save in the editor, ⇧⌘R to run all, ⇧⌘. to stop all, and Escape to close a dialog.

## AI Skill

Open **AI Skill** (⇧⌘K) in Manager to select a skills directory and generate `scriptser-control`, containing `SKILL.md`, `references/cli.md`, and `scripts/scriptserctl.py`. The default is `~/.codex/skills`, or `$CODEX_HOME/skills` when available to the app. The directory is remembered. In Codex, invoke `$scriptser-control` in a new chat, or use **Copy Adding Prompt** to load its absolute path.

The skill uses Python 3's standard library and Scriptser's native local JSON API. No computer-use tool, Accessibility permission, desktop clicks, or additional service is needed. It works while the screen is locked, provided Scriptser remains running in the logged-in user's session and the Mac is awake.

```sh
python3 ~/.codex/skills/scriptser-control/scripts/scriptserctl.py status
python3 ~/.codex/skills/scriptser-control/scripts/scriptserctl.py scripts.list
python3 ~/.codex/skills/scriptser-control/scripts/scriptserctl.py scripts.run --params '{"id":"SCRIPT_UUID"}'
```

The API manages definitions, execution, output, imports/exports, settings, skill generation, and app updates through the same store as the UI. Commands and multiline data can be supplied with `--params-file`. `run` acknowledges starting a process; inspect status, exit code, and output for completion. Update actions return acceptance and expose progress via `updates.status`. Errors are structured JSON; the client never retries a mutation automatically or silently launches the app. `launch` explicitly opens it, which can execute enabled at-launch scripts.

The Unix socket is `~/Library/Application Support/Scriptser/control.sock`, mode 0600, with same-user peer checks and a single-instance lock. It exposes no TCP port. DEV uses `Scriptser-DEV/control.sock` and generates `scriptser-dev-control`. The [bundled API reference](Sources/Scriptser/Resources/Skills/scriptser-control/references/cli.md) documents the protocol and methods.

Generation upgrades the legacy UI skill to code control, replaces bundled instructions/client, removes the obsolete bundled UI guide, and preserves additional files. Unrelated skills and symlinks at managed paths are rejected. Regenerate after moving the app to refresh its launch target. Older Scriptser versions need to be upgraded to 1.3.1+ before using this skill.

## Process details and application icon

Expand a running script’s details in Manager or the menu bar, or open its Output viewer, to see the tracked process **PID**. **Stop** sends normal termination. **End Process** confirms the script name and PID, then sends `SIGKILL` to that tracked process. The action rejects a confirmation for an old PID after a script restarts. It affects the tracked shell process, not an entire process tree. PID is cleared when execution ends, and recovered running scripts display their persisted PID.

The bundled macOS app icon is shared by the shipping and DEV app. Its reproducible AppKit source is `tools/generate-app-icon.swift`; run the commands in that file to regenerate `Resources/AppIcon.icns`.

## Updates

**Check for Updates…** is available in Manager and the menu bar. It contacts the public GitHub API for the latest stable release from [zero-times/scriptser Releases](https://github.com/zero-times/scriptser/releases). Concurrent checks share one request, and checks within 60 seconds reuse the result. If GitHub returns an API quota error, Scriptser checks the official latest-release webpage and avoids retrying the API until its quota reset. In this fallback, package metadata is unavailable, so use **Visit Releases** to download the installer. Errors are presented only at the initiating update control. Checks run only when requested; drafts and prereleases are excluded, and equal or older versions are never offered as updates.

For a newer release, view the release notes and choose **Install and Restart**. Scriptser downloads the package with live progress, verifies its size and GitHub's SHA-256 digest when provided, mounts the `.dmg` or extracts the `.zip`, stages the replacement app, then swaps the bundle and relaunches automatically after quitting. Scripts and preferences stay in their existing locations. Automatic in-place installation applies to the production app; the DEV build and `.pkg` packages keep the manual fallback, where **Download Update…** saves the verified package and **Open Download** opens it for a manual replacement in Applications.

To build a universal DMG and `SHA256SUMS.txt` from the version set in the Xcode project, run `zsh tools/build-release.sh 1.3.1`. The script verifies the packaged version and architectures, then applies an ad-hoc signature. Artifacts are written to `.build/releases/v1.3.1/`.

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

Tests use temporary configuration files and isolated preferences to cover configuration compatibility, language resources, automatic execution, process recovery, duplicate prevention, failure handling, GitHub version checks, package selection, verified update downloads, code-control CRUD and process operations, socket ownership/framing, Python client integration, and legacy skill upgrades.

macOS Login Items registration requires a properly bundled application. If macOS requests approval, enable Scriptser in System Settings → General → Login Items. Validate login registration in the signed application on the target Mac.

## Local DEV app

Run `zsh tools/build-dev.sh` to build a DEV app from the same entry point and views as the shipping app. DEV uses `~/Library/Application Support/Scriptser-DEV/config.json`, keeps its own preferences, and does not register a login item. Its single manager window is also reachable from the Dock. The build is ad-hoc signed for local verification.
