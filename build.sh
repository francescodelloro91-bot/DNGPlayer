#!/bin/sh
# Compila DNGPlayer.app in /Applications.
set -e
cd "$(dirname "$0")"
APP=/Applications/DNGPlayer.app
mkdir -p "$APP/Contents/MacOS"
# Icona: icon_1024.png (da make-icon.swift) -> AppIcon.icns
I=$(mktemp -d)/AppIcon.iconset
mkdir -p "$I" "$APP/Contents/Resources"
for s in 16 32 128 256 512; do
  sips -z $s $s icon_1024.png --out "$I/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) icon_1024.png --out "$I/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$I" -o "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -parse-as-library DNGPlayer.swift -o "$APP/Contents/MacOS/DNGPlayer"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>DNGPlayer</string>
<key>CFBundleIdentifier</key><string>it.frank.dngplayer</string>
<key>CFBundleExecutable</key><string>DNGPlayer</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP"
echo "OK: $APP"
