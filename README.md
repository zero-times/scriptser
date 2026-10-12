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
- Commands are fully custom. The former Docker Quick Commands and pattern-based quick actions have been removed; saved script commands remain intact.
- Use **Output** for live output, copying, clearing, and automatic scrolling. Output buffers are in memory and do not survive app restarts.

## Language and navigation

Choose **Follow System**, **简体中文**, or **English** in Manager. Language changes apply immediately to the menu, editor, output viewer, and app error messages, and are remembered across launches. Commands, script names, and raw shell output remain as entered.

Manager has **All Scripts**, **Running**, and **At Launch** filters. Search matches names, commands, directories, and tags. The menu bar list scrolls when there are many scripts.

Shortcuts: ⌘N to add a script, ⌘F to search, ⌘S to save in the editor, ⇧⌘R to run all, ⇧⌘. to stop all, and Escape to close a dialog.

## Updates

**Check for Updates…** is available in Manager and the menu bar. It contacts the public GitHub API for the latest stable release from [zero-times/scriptser Releases](https://github.com/zero-times/scriptser/releases). Checks run only when requested; drafts and prereleases are excluded, and equal or older versions are never offered as updates.

For a newer release, view the release notes and choose **Download Update…**. Scriptser selects a compatible macOS `.dmg`, `.zip`, or `.pkg`, saves it to your chosen location, and verifies its size and GitHub's SHA-256 digest when provided. **Open Download** opens the package for installation. Quit Scriptser and replace the application in Applications (or complete the package installer); scripts and preferences stay in their existing locations. Scriptser does not replace a running application itself.

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
