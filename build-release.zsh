#!/bin/zsh
#
# Baut die Release-Version der App, installiert sie nach
# /Applications und löscht danach den Ordner ./build.
#
# Aufruf: ./build-release.zsh
#

set -euo pipefail

SCRIPT_DIR=${0:A:h}
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="gcodeViewer.app"
BUNDLE_ID="de.adcore.gcodeViewer"
TARGET="/Applications/$APP_NAME"
BUILT_APP="$BUILD_DIR/Build/Products/Release/$APP_NAME"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# ./build wird am Ende immer gelöscht, auch wenn etwas schiefgeht.
cleanup() {
    if [[ -d $BUILT_APP ]]; then
        # Xcode meldet den Build bei macOS an; abmelden, damit .md-Dateien
        # nicht in einer gelöschten Kopie geöffnet werden.
        $LSREGISTER -u "$BUILT_APP" 2>/dev/null || true
    fi
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

bundle_id() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null || true
}

# Nicht über eine laufende App kopieren.
if pgrep -qf "$TARGET/Contents/MacOS/"; then
    print -u2 "Fehler: $APP_NAME läuft noch. Bitte zuerst beenden."
    exit 1
fi

# Keine fremde App mit gleichem Namen überschreiben.
if [[ -e $TARGET && $(bundle_id "$TARGET") != "$BUNDLE_ID" ]]; then
    print -u2 "Fehler: $TARGET gehört nicht zu $BUNDLE_ID (gefunden: $(bundle_id "$TARGET"))."
    exit 1
fi

print "==> Baue Release-Version …"
xcodebuild \
    -project "$SCRIPT_DIR/gcodeViewer.xcodeproj" \
    -scheme gcodeViewer \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$BUILD_DIR" \
    -quiet \
    build

if [[ $(bundle_id "$BUILT_APP") != "$BUNDLE_ID" ]]; then
    print -u2 "Fehler: Build nicht gefunden unter $BUILT_APP."
    exit 1
fi

print "==> Installiere nach $TARGET …"
rm -rf "$TARGET"
ditto "$BUILT_APP" "$TARGET"
$LSREGISTER -f "$TARGET"

print "==> Registriere Quick-Look-Erweiterungen …"
# Ältere Kopien (DerivedData, Archive, alte Builds) abmelden, sonst nimmt
# Quick Look womöglich eine davon statt der installierten Version.
for ext_id in de.adcore.gcodeViewer.gcodeViewerQL de.adcore.gcodeViewer.gcodeViewerQLThumbnail; do
    pluginkit -m -A -v -v -i "$ext_id" 2>/dev/null \
        | sed -n 's/^ *Path = //p' \
        | while read -r ext_path; do
            if [[ $ext_path != "$TARGET"/* ]]; then
                pluginkit -r "$ext_path" 2>/dev/null || true
                $LSREGISTER -u "${ext_path%/Contents/PlugIns/*}" 2>/dev/null || true
            fi
        done
done
pluginkit -a "$TARGET"/Contents/PlugIns/*.appex
pluginkit -e use -i de.adcore.gcodeViewer.gcodeViewerQL
pluginkit -e use -i de.adcore.gcodeViewer.gcodeViewerQLThumbnail
# Quick-Look-Cache leeren, damit Finder die Vorschaubilder neu erzeugt.
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$TARGET/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$TARGET/Contents/Info.plist")
print "==> Fertig: $APP_NAME $version ($build) ist installiert."
