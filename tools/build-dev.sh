#!/bin/zsh
set -eu

task_repo_root="${0:A:h:h}"
task_app_dir="${1:-$task_repo_root/.build/dev/Scriptser DEV.app}"
task_arch="$(uname -m)"
mkdir -p "$task_app_dir/Contents/MacOS" "$task_app_dir/Contents/Resources"
task_sources=("$task_repo_root"/Sources/Scriptser/**/*.swift)
xcrun swiftc -parse-as-library -module-name ScriptserDev \
  -target "$task_arch-apple-macosx13.0" -sdk "$(xcrun --show-sdk-path)" \
  "${task_sources[@]}" -o "$task_app_dir/Contents/MacOS/ScriptserDev"
cp -R "$task_repo_root/Sources/Scriptser/Resources/en.lproj" "$task_app_dir/Contents/Resources/"
cp -R "$task_repo_root/Sources/Scriptser/Resources/zh-Hans.lproj" "$task_app_dir/Contents/Resources/"
mkdir -p "$task_app_dir/Contents/Resources/Skills"
cp -R "$task_repo_root/Sources/Scriptser/Resources/Skills/scriptser-control" "$task_app_dir/Contents/Resources/Skills/"
cp "$task_repo_root/Sources/Scriptser/Resources/AppIcon.icns" "$task_app_dir/Contents/Resources/"
cat > "$task_app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Scriptser DEV</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>ScriptserDev</string>
<key>CFBundleIdentifier</key><string>com.scriptser.scr1.preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3.1</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$task_app_dir"
printf '%s\n' "$task_app_dir"
