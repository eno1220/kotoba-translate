#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

swift build -c release "$@"
bin_dir=$(swift build -c release --show-bin-path "$@")
app="$PWD/dist/Kotoba Translate.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
iconset="$PWD/.build/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
cp "$bin_dir/KotobaTranslate" "$app/Contents/MacOS/"
# Keep the original build artifact for debugging; strip only the packaged copy.
xcrun strip -S -x "$app/Contents/MacOS/KotobaTranslate"
for resource in "$bin_dir"/*.bundle(N); do
    cp -R "$resource" "$app/Contents/Resources/"
done
# Python bytecode caches are generated locally and are not app resources.
find "$app/Contents/Resources" -type d -name __pycache__ -prune -exec rm -rf {} +
printf '%s\n' "$PWD/.venv/bin/python" > "$app/Contents/Resources/python-path.txt"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>Kotoba Translate</string>
    <key>CFBundleDisplayName</key><string>Kotoba Translate</string>
    <key>CFBundleIdentifier</key><string>local.kotoba.translate</string>
    <key>CFBundleExecutable</key><string>KotobaTranslate</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSRequiresAquaSystemAppearance</key><true/>
    <key>NSServices</key><array><dict>
        <key>NSMenuItem</key><dict>
            <key>default</key><string>Kotoba Translateに送る</string>
        </dict>
        <key>NSMessage</key><string>importSelection</string>
        <key>NSPortName</key><string>KotobaTranslate</string>
        <key>NSSendTypes</key><array><string>public.utf8-plain-text</string></array>
        <key>NSRequiredContext</key><dict/>
    </dict></array>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app"
printf '%s\n' "$app"
