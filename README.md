# Scriptser

A lightweight macOS menu bar app for managing local scripts. It runs only on your Mac and does not use any network services.

## Run

Open the Xcode project:

```
cd scriptser
open Scriptser.xcodeproj
```

Click Run in Xcode to launch the menu bar app.

## First-time setup

The app stores its config at:

```
~/Library/Application Support/Scriptser/config.json
```

You can add scripts from the Manager window in the menu bar.

## Notes

- The app uses `zsh -lc` to execute commands.
- A script can optionally set a working directory.
