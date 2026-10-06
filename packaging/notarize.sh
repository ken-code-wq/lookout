#!/bin/zsh
# Re-signs Lookout.app with a Developer ID and the hardened runtime, has Apple notarize it, and staples the
# ticket so Gatekeeper opens it without the xattr step. release.sh calls this when a Developer ID exists.
#
# Needs, once:
#   1. An Apple Developer Program membership (paid; https://developer.apple.com/programs/).
#   2. A "Developer ID Application" certificate in your login keychain: Xcode › Settings › Accounts ›
#      Manage Certificates › + › Developer ID Application, or developer.apple.com › Certificates.
#   3. A notarytool keychain profile, using an app-specific password from account.apple.com:
#        xcrun notarytool store-credentials lookout-notary --apple-id you@example.com --team-id TEAMID
#
# usage: notarize.sh [Lookout.app]
#   LOOKOUT_DEVELOPER_ID    signing identity (default: the first "Developer ID Application" in the keychain)
#   LOOKOUT_NOTARY_PROFILE  notarytool keychain profile (default: lookout-notary)
set -euo pipefail
cd "$(dirname "$0")/.."
APP=${1:-Lookout.app}
PROFILE=${LOOKOUT_NOTARY_PROFILE:-lookout-notary}
IDENTITY=${LOOKOUT_DEVELOPER_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')}

if [[ -z "$IDENTITY" ]]; then
  cat >&2 <<'MSG'
error: no "Developer ID Application" signing identity in your keychain.
Notarization needs an Apple Developer Program membership ($99/year) and a Developer ID Application
certificate (Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application).
Then store notarytool credentials once, with an app-specific password from account.apple.com:
  xcrun notarytool store-credentials lookout-notary --apple-id you@example.com --team-id TEAMID
The self-made "Lookout Local Signing" certificate can't be notarized.
MSG
  exit 1
fi
[[ -d "$APP" ]] || { echo "error: $APP not found; run packaging/build-app.sh first" >&2; exit 1; }
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "error: no notarytool keychain profile named '$PROFILE'. Create it with:" >&2
  echo "  xcrun notarytool store-credentials $PROFILE --apple-id you@example.com --team-id TEAMID" >&2
  exit 1
fi

echo "Signing $APP as $IDENTITY"
SIGN=(--force --sign "$IDENTITY" --options runtime --timestamp)
# Inside out. Every Mach-O must carry the Developer ID and a secure timestamp for the notary service to accept it.
packaging/sign-sparkle.sh "$APP/Contents/Frameworks/Sparkle.framework" "$IDENTITY" --options runtime --timestamp
# Loaded by /usr/bin/perl, not by the app, but it ships in the bundle, so it's signed like the rest.
codesign "${SIGN[@]}" "$APP/Contents/Resources/libNowPlayingBridge.dylib"
codesign "${SIGN[@]}" "$APP/Contents/MacOS/lookout-hook"
codesign "${SIGN[@]}" "$APP/Contents/Helpers/lookout"
codesign "${SIGN[@]}" --entitlements packaging/Widgets.entitlements "$APP/Contents/PlugIns/LocalObserverWidgets.appex"
codesign "${SIGN[@]}" --entitlements packaging/Lookout.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$WORK/Lookout.zip"
echo "Submitting to Apple's notary service (usually a few minutes)…"
xcrun notarytool submit "$WORK/Lookout.zip" --keychain-profile "$PROFILE" --wait --output-format plist > "$WORK/result.plist"
STATUS=$(/usr/libexec/PlistBuddy -c 'Print :status' "$WORK/result.plist" 2>/dev/null || echo unknown)
ID=$(/usr/libexec/PlistBuddy -c 'Print :id' "$WORK/result.plist" 2>/dev/null || echo "")
if [[ "$STATUS" != "Accepted" ]]; then
  echo "error: notarization finished with status '$STATUS'." >&2
  [[ -n "$ID" ]] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
  exit 1
fi

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv -t exec "$APP"
echo "Notarized and stapled $APP"
