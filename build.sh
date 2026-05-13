swift build
BIN_DIR="$(swift build --show-bin-path)"
mkdir -p "Inboxed.app/Contents/MacOS" "Inboxed.app/Contents/Resources"
cp "$BIN_DIR/Inboxed" "Inboxed.app/Contents/MacOS/Inboxed"
cp "Resources/Inboxed.icns" "Inboxed.app/Contents/Resources/Inboxed.icns"
cat > "Inboxed.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Inboxed</string>
  <key>CFBundleIdentifier</key>
  <string>dev.inboxed.Inboxed</string>
  <key>CFBundleName</key>
  <string>Inboxed</string>
  <key>CFBundleDisplayName</key>
  <string>Inboxed</string>
  <key>CFBundleIconFile</key>
  <string>Inboxed</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF
codesign --force --deep --sign - "Inboxed.app"
open "Inboxed.app"
