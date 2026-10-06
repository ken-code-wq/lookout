#!/bin/zsh
# Re-signs an embedded Sparkle.framework inside out, as Sparkle's docs require: XPC services, Autoupdate,
# Updater.app, then the framework itself. Any extra arguments go to codesign (notarize.sh passes
# --options runtime --timestamp).
# usage: sign-sparkle.sh <Sparkle.framework> <identity> [codesign flags…]
set -euo pipefail
FRAMEWORK=$1 IDENTITY=$2
shift 2
B="$FRAMEWORK/Versions/B"
codesign --force --sign "$IDENTITY" "$@" "$B/XPCServices/Installer.xpc"
# The downloader keeps its network-client entitlement.
codesign --force --sign "$IDENTITY" "$@" --preserve-metadata=entitlements "$B/XPCServices/Downloader.xpc"
codesign --force --sign "$IDENTITY" "$@" "$B/Autoupdate"
codesign --force --sign "$IDENTITY" "$@" "$B/Updater.app"
codesign --force --sign "$IDENTITY" "$@" "$FRAMEWORK"
