#!/bin/zsh
# Builds release binaries and refreshes Lookout.app (app, widget extension, icon) next to the package.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=Lookout.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LocalObserver "$APP/Contents/MacOS/LocalObserver"
# Agent hook helper, run by Claude Code and Codex hooks (Settings › Agents › Live hooks). Lives next to the app's
# executable so the path written into agents' configs stays put across rebuilds.
cp .build/release/lookout-hook "$APP/Contents/MacOS/lookout-hook"
cp packaging/Info.plist "$APP/Contents/Info.plist"
# Sparkle: the framework sits in Contents/Frameworks, where the app looks for it at runtime.
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/LocalObserver"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto .build/release/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
# The updater only runs with the EdDSA public key that verifies updates (printed by Sparkle's generate_keys).
# Without one it stays off; see Sources/LocalObserver/Core/Updater.swift.
if [[ -n "${LOOKOUT_SPARKLE_PUBLIC_KEY:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $LOOKOUT_SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
else
  echo "note: LOOKOUT_SPARKLE_PUBLIC_KEY isn't set, so this build won't update itself"
fi
# Rendered from packaging/icon/make-icon.swift.
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Agent icons live in the core module's resource bundle.
rm -rf "$APP/Contents/Resources/LocalObserver_LocalObserverCore.bundle"
cp -R .build/release/LocalObserver_LocalObserverCore.bundle "$APP/Contents/Resources/"
# Now Playing bridge, loaded by /usr/bin/perl at runtime (see MediaController).
cp .build/release/libNowPlayingBridge.dylib "$APP/Contents/Resources/"
# Desktop widgets: WidgetKit extension, sandboxed, reading the snapshot the app writes (see WidgetPublisher).
APPEX="$APP/Contents/PlugIns/LocalObserverWidgets.appex"
rm -rf "$APPEX"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
cp .build/release/LocalObserverWidgets "$APPEX/Contents/MacOS/LocalObserverWidgets"
cp packaging/WidgetInfo.plist "$APPEX/Contents/Info.plist"
cp -R .build/release/LocalObserver_LocalObserverCore.bundle "$APPEX/Contents/Resources/"
# `lookout` CLI, symlinked onto the PATH from Settings › Automation.
mkdir -p "$APP/Contents/Helpers"
cp .build/release/lookout "$APP/Contents/Helpers/lookout"
# Shortcuts only lists App Intents from a bundle with Metadata.appintents, which Xcode's
# appintentsmetadataprocessor generates. It ships with Xcode only (not the Command Line Tools), so this is
# best effort: skipped without Xcode, and a failure never breaks the build. See Sources/LocalObserver/Core/LookoutIntents.swift.
packaging/appintents-metadata.sh "$APP" || echo "warning: App Intents metadata step failed; Shortcuts won't list Lookout's actions"
# Sign with a real certificate when there is one: macOS won't list widgets from an ad-hoc signed extension,
# and a stable identity keeps privacy permissions (audio capture, automation) across rebuilds.
# Create one with packaging/make-signing-cert.sh; without it the build falls back to ad-hoc (no widgets).
IDENTITY=$(security find-identity -p codesigning | awk -F'"' '/Lookout Local Signing/ { print $2; exit }')
[[ -z "$IDENTITY" ]] && { echo "warning: no 'Lookout Local Signing' identity, signing ad-hoc (widgets won't appear)"; IDENTITY=-; }
# Inside out: the helper and the extension (with its sandbox entitlements) first, then the app around them.
packaging/sign-sparkle.sh "$APP/Contents/Frameworks/Sparkle.framework" "$IDENTITY"
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/lookout-hook"
codesign --force --sign "$IDENTITY" "$APP/Contents/Helpers/lookout"
codesign --force --sign "$IDENTITY" --entitlements packaging/Widgets.entitlements "$APPEX"
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP — open it with: open $APP"
echo "Widgets: right-click the desktop › Edit Widgets › Lookout (the app must have run once)."
