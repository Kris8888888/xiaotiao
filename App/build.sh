#!/bin/bash
# 构建「小条.app」通用版（Apple 芯片 + Intel），ad-hoc 签名，产出 zip 与 dmg
set -euo pipefail
cd "$(dirname "$0")"
APP_NAME="小条"; EXE="Xiaotiao"; OUT="build"; APP="$OUT/$APP_NAME.app"; MIN="13.0"
rm -rf "$OUT"; mkdir -p "$OUT/arm64" "$OUT/x86_64" "$APP/Contents/MacOS" "$APP/Contents/Resources"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
COMMON=(-O -swift-version 5 -sdk "$SDK" -parse-as-library -module-name Xiaotiao Sources/*.swift -framework AppKit -framework SwiftUI -framework Carbon -framework ServiceManagement)
echo "编译 arm64…";  swiftc "${COMMON[@]}" -target arm64-apple-macos$MIN  -o "$OUT/arm64/$EXE"
echo "编译 x86_64…"; swiftc "${COMMON[@]}" -target x86_64-apple-macos$MIN -o "$OUT/x86_64/$EXE"
lipo -create "$OUT/arm64/$EXE" "$OUT/x86_64/$EXE" -output "$APP/Contents/MacOS/$EXE"
echo "生成图标…"; swiftc -O -sdk "$SDK" tools/MakeIcon.swift -o "$OUT/MakeIcon" -framework AppKit; "$OUT/MakeIcon" "$OUT/AppIcon.iconset"; iconutil -c icns "$OUT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"; echo -n "APPL????" > "$APP/Contents/PkgInfo"
echo "签名…"; codesign --force --deep --sign - --identifier com.likang.xiaotiao "$APP"
echo "打包…"; (cd "$OUT" && ditto -c -k --keepParent "$APP_NAME.app" "$APP_NAME.zip")
rm -rf "$OUT/dmgroot"; mkdir -p "$OUT/dmgroot"; cp -R "$APP" "$OUT/dmgroot/"; ln -s /Applications "$OUT/dmgroot/拖到这里安装"
hdiutil create -volname "$APP_NAME" -srcfolder "$OUT/dmgroot" -ov -format UDZO "$OUT/$APP_NAME.dmg" >/dev/null
echo "完成：$APP"; lipo -info "$APP/Contents/MacOS/$EXE"
