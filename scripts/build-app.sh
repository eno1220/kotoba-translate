#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

swift build -c release "$@"
bin_dir=$(swift build -c release --show-bin-path "$@")
app="$PWD/dist/Kotoba Translate.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/KotobaTranslate" "$app/Contents/MacOS/"
for resource in "$bin_dir"/*.bundle(N); do
    cp -R "$resource" "$app/Contents/Resources/"
done
printf '%s\n' "$PWD/.venv/bin/python" > "$app/Contents/Resources/python-path.txt"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>Kotoba Translate</string>
    <key>CFBundleDisplayName</key><string>Kotoba Translate</string>
    <key>CFBundleIdentifier</key><string>local.kotoba.translate</string>
    <key>CFBundleExecutable</key><string>KotobaTranslate</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSRequiresAquaSystemAppearance</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app"
printf '%s\n' "$app"
