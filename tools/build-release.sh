#!/bin/zsh
# Build and package the universal macOS app with the same ad-hoc signing as prior releases.
set -eu

task_repo_root="${0:A:h:h}"
task_version="${1:?Usage: tools/build-release.sh VERSION}"
task_release_dir="$task_repo_root/.build/releases/v$task_version"
task_build_dir="$task_repo_root/.build/release-v$task_version"
task_products_dir="$task_build_dir/products"
task_stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/scriptser-package.XXXXXX")"
trap 'rm -rf "$task_stage_dir"' EXIT
mkdir -p "$task_release_dir"

xcodebuild -project "$task_repo_root/Scriptser.xcodeproj" -scheme Scriptser \
  -configuration Release -derivedDataPath "$task_build_dir" \
  CONFIGURATION_BUILD_DIR="$task_products_dir" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build

task_app="$task_stage_dir/Scriptser.app"
ditto "$task_products_dir/Scriptser.app" "$task_app"
task_built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$task_app/Contents/Info.plist")"
if [[ "$task_built_version" != "$task_version" ]]; then
  print -u2 "Requested $task_version but app version is $task_built_version"
  exit 1
fi
task_architectures=" $(lipo -archs "$task_app/Contents/MacOS/Scriptser") "
if [[ "$task_architectures" != *' arm64 '* || "$task_architectures" != *' x86_64 '* ]]; then
  print -u2 "Expected arm64 and x86_64, got:$task_architectures"
  exit 1
fi
codesign --force --sign - --timestamp=none "$task_app"
codesign --verify --deep --strict "$task_app"
ln -s /Applications "$task_stage_dir/Applications"
task_package="Scriptser-$task_version-universal.dmg"
hdiutil create -volname "Scriptser $task_version" -srcfolder "$task_stage_dir" \
  -format UDZO -ov "$task_release_dir/$task_package"
(cd "$task_release_dir" && shasum -a 256 "$task_package" > SHA256SUMS.txt)
print "Release package: $task_release_dir/$task_package"
