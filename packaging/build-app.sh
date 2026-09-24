#!/bin/zsh
# Builds a release binary and refreshes LocalObserver.app next to the package.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=LocalObserver.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LocalObserver "$APP/Contents/MacOS/LocalObserver"
cp packaging/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP — open it with: open $APP"
