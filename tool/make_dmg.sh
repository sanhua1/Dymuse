#!/bin/sh
# 把 Dymuse.app 打成常见的“拖到应用程序”安装盘（需要在有图形界面的 Mac 上运行，用 Finder 摆放图标）。
# 用法：sh tool/make_dmg.sh build/macos/Build/Products/Release/Dymuse.app Dymuse-macos.dmg
set -e
APP="$1"; OUT="$2"
VOL="Dymuse"
WORK="$(mktemp -d)"
RW="$WORK/rw.dmg"
mkdir "$WORK/src"
ditto "$APP" "$WORK/src/Dymuse.app"
ln -s /Applications "$WORK/src/Applications"
hdiutil create -volname "$VOL" -srcfolder "$WORK/src" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
DEV="$(hdiutil attach "$RW" -noverify -noautoopen | sed -n 's|^\(/dev/disk[0-9]*\).*Apple_HFS.*|\1|p' | head -1)"
chflags hidden "/Volumes/$VOL/.fseventsd" "/Volumes/$VOL/.Trashes" 2>/dev/null || true
osascript <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 140, 740, 480}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set position of item "Dymuse.app" of container window to {140, 160}
    set position of item "Applications" of container window to {400, 160}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
bless --folder "/Volumes/$VOL" --openfolder "/Volumes/$VOL" 2>/dev/null || true
rm -rf "/Volumes/$VOL/.fseventsd"
sync
hdiutil detach "$DEV" >/dev/null
rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
echo "$OUT"
