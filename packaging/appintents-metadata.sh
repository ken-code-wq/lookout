#!/bin/zsh
# Generates Contents/Resources/Metadata.appintents for Lookout.app, which Shortcuts needs to list its App Intents.
# Xcode does this with appintentsmetadataprocessor after compiling; SwiftPM doesn't. This replays that step:
# extract the intents' constant values with swiftc, then run the processor on the release binary.
# Needs Xcode (the processor isn't in the Command Line Tools). Without it, exits 0 and says so.
# Unverified on a Command Line Tools-only Mac; build-app.sh treats a failure as a warning.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=${1:-Lookout.app}
PROCESSOR=$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)
if [[ -z "$PROCESSOR" ]]; then
  echo "note: appintentsmetadataprocessor not found (it ships with Xcode); Shortcuts actions won't be listed in this build"
  exit 0
fi
WORK=.build/appintents
rm -rf "$WORK"; mkdir -p "$WORK"
SDK=$(xcrun --sdk macosx --show-sdk-path)
TOOLCHAIN=$(cd "$(dirname "$PROCESSOR")/../.." && pwd)
TRIPLE=arm64-apple-macos14.2
SOURCES=(${(f)"$(find Sources/LocalObserver -name '*.swift' | sort)"})
print -l -- "${SOURCES[@]:A}" > "$WORK/LocalObserver.SwiftFileList"
# The protocols Xcode asks the compiler to gather constant values for.
cat > "$WORK/protocols.json" <<'JSON'
["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider"]
JSON
xcrun swiftc -typecheck -module-name LocalObserver -target "$TRIPLE" -sdk "$SDK" -I .build/release/Modules \
  "${SOURCES[@]}" -emit-const-values-path "$WORK/LocalObserver.swiftconstvalues" \
  -Xfrontend -const-gather-protocols-file -Xfrontend "$WORK/protocols.json" 2>/dev/null
echo "${WORK:A}/LocalObserver.swiftconstvalues" > "$WORK/LocalObserver.SwiftConstValuesFileList"
: > "$WORK/LocalObserver.DependencyMetadataFileList"
: > "$WORK/LocalObserver.DependencyStaticMetadataFileList"
"$PROCESSOR" \
  --toolchain-dir "$TOOLCHAIN" \
  --module-name LocalObserver \
  --sdk-root "$SDK" \
  --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
  --platform-family macOS \
  --deployment-target 14.2 \
  --bundle-identifier "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" \
  --output "$APP/Contents/Resources" \
  --target-triple "$TRIPLE" \
  --binary-file "$APP/Contents/MacOS/LocalObserver" \
  --dependency-file "$WORK/dependency_info.dat" \
  --stringsdata-file "$WORK/ExtractedAppShortcutsMetadata.stringsdata" \
  --source-file-list "$WORK/LocalObserver.SwiftFileList" \
  --metadata-file-list "$WORK/LocalObserver.DependencyMetadataFileList" \
  --static-metadata-file-list "$WORK/LocalObserver.DependencyStaticMetadataFileList" \
  --swift-const-vals-list "$WORK/LocalObserver.SwiftConstValuesFileList" \
  --compile-time-extraction \
  --deployment-aware-processing \
  --no-app-shortcuts-localization
if [[ -d "$APP/Contents/Resources/Metadata.appintents" ]]; then
  echo "App Intents metadata: $APP/Contents/Resources/Metadata.appintents"
else
  echo "warning: the processor ran but produced no Metadata.appintents"; exit 1
fi
