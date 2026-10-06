#!/bin/zsh
# Builds a release: Lookout.app (notarized when a Developer ID is available), dist/Lookout.zip signed for
# Sparkle, and a new entry at the top of appcast.xml. Publishes nothing; it prints the steps that do.
#
# One-time setup: run Sparkle's generate_keys once (.build/artifacts/sparkle/Sparkle/bin/generate_keys after
# `swift package resolve`). It keeps the private key in your login keychain, where sign_update finds it, and
# prints the public key, which this script reads back with `generate_keys -p`.
#
# Before each release, bump CFBundleShortVersionString and CFBundleVersion in packaging/Info.plist; Sparkle
# compares CFBundleVersion. Optional: LOOKOUT_RELEASE_NOTES=notes.html for the update dialog.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=ken-code-wq/lookout
PLIST=packaging/Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")
TAG="v$VERSION"

swift package resolve
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
[[ -x "$SPARKLE_BIN/sign_update" ]] || { echo "error: Sparkle's tools aren't at $SPARKLE_BIN"; exit 1; }

if [[ -f appcast.xml ]] && grep -q "<sparkle:version>$BUILD</sparkle:version>" appcast.xml; then
  echo "error: appcast.xml already has build $BUILD. Bump CFBundleVersion (and the version) in $PLIST."; exit 1
fi

# The public key goes into Info.plist so the app can verify what it downloads.
if [[ -z "${LOOKOUT_SPARKLE_PUBLIC_KEY:-}" ]]; then
  LOOKOUT_SPARKLE_PUBLIC_KEY=$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null || true)
fi
if [[ -z "$LOOKOUT_SPARKLE_PUBLIC_KEY" ]]; then
  echo "error: no Sparkle key in the keychain. Run $SPARKLE_BIN/generate_keys once, then try again."; exit 1
fi
export LOOKOUT_SPARKLE_PUBLIC_KEY

packaging/build-app.sh

# No extended attributes in the archive, so nothing (quarantine included) rides along from this Mac.
mkdir -p dist
rm -f dist/Lookout.zip
xattr -cr Lookout.app
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl Lookout.app dist/Lookout.zip

# EdDSA signature and length for the enclosure, e.g. sparkle:edSignature="…" length="123".
SIGNATURE=$("$SPARKLE_BIN/sign_update" dist/Lookout.zip)
[[ "$SIGNATURE" == *edSignature* ]] || { echo "error: sign_update failed: $SIGNATURE"; exit 1; }

NOTES=""
if [[ -n "${LOOKOUT_RELEASE_NOTES:-}" ]]; then
  NOTES="      <description><![CDATA[$(cat "$LOOKOUT_RELEASE_NOTES")]]></description>"
fi
ITEM=$(mktemp)
cat > "$ITEM" <<XML
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
$NOTES
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/Lookout.zip" type="application/octet-stream" $SIGNATURE/>
    </item>
XML
sed -i '' '/^$/d' "$ITEM"

if [[ ! -f appcast.xml ]]; then
  cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Lookout</title>
    <link>https://github.com/$REPO</link>
    <description>Lookout updates</description>
    <language>en</language>
  </channel>
</rss>
XML
fi
# Newest first: before the first existing item, or at the end of the channel when there is none.
awk -v item="$ITEM" '
  !done && (/<item>/ || /<\/channel>/) { while ((getline line < item) > 0) print line; done = 1 }
  { print }
' appcast.xml > appcast.xml.new && mv appcast.xml.new appcast.xml
rm -f "$ITEM"

echo
echo "Built dist/Lookout.zip ($VERSION, build $BUILD) and added it to appcast.xml. To publish:"
echo "  1. gh release create $TAG dist/Lookout.zip --repo $REPO --title \"Lookout $VERSION\""
echo "  2. git add appcast.xml $PLIST && git commit -m \"release: $VERSION\" && git push"
echo "     (after the zip is uploaded: the appcast points at it, and apps check it from main)"
