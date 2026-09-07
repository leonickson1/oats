#!/bin/zsh
# Builds the branded "Drag to Install" DMG around an already-signed Oats.app.
#
#   ./build-dmg.sh /path/to/Oats.app /path/to/output/Oats.dmg
#
# Needs a GUI session (Finder lays out the window) and no other volume
# named "Oats" mounted. Sign and notarize the result afterwards; see
# RELEASING.md.
set -e -o pipefail
cd "$(dirname "$0")"

APP="$1"
OUT="$2"
[[ -d "$APP" && -n "$OUT" ]] || { echo "usage: build-dmg.sh Oats.app out.dmg"; exit 1 }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Background: 1x + 2x PNGs combined into a hidpi TIFF so text is crisp on Retina.
python3 bg.py
mkdir -p "$WORK/stage/.background"
tiffutil -cathidpicheck bg.png bg@2x.png -out "$WORK/stage/.background/oats-bg.tiff"
rm -f bg.png "bg@2x.png"

ditto "$APP" "$WORK/stage/Oats.app"
ln -s /Applications "$WORK/stage/Applications"
cp "$WORK/stage/Oats.app/Contents/Resources/AppIcon.icns" "$WORK/stage/.VolumeIcon.icns"

hdiutil create -volname Oats -srcfolder "$WORK/stage" -ov -fs HFS+ -format UDRW "$WORK/rw.dmg" -quiet
hdiutil attach "$WORK/rw.dmg" -noverify -noautoopen -quiet
SetFile -a C /Volumes/Oats   # use .VolumeIcon.icns as the volume icon

# The window: 660x508 outer, background 660x480 with cream slack at the bottom
# so the note box stays visible whether or not Finder shows a tab bar.
osascript <<'EOF'
tell application "Finder"
  tell disk "Oats"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 628}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:oats-bg.tiff"
    set position of item "Oats.app" of container window to {180, 215}
    set position of item "Applications" of container window to {480, 215}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
sync
hdiutil detach /Volumes/Oats -quiet

rm -f "$OUT"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet
echo "built $OUT (unsigned; codesign + notarize next, see RELEASING.md)"
