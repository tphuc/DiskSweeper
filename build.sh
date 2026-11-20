#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=DiskSweeper.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
swiftc -O -swift-version 5 -parse-as-library DiskSweeper.swift -o $APP/Contents/MacOS/DiskSweeper
xcrun actool DiskSweeper.icon --compile $APP/Contents/Resources --app-icon DiskSweeper \
  --platform macosx --minimum-deployment-target 14.0 \
  --output-partial-info-plist /dev/null >/dev/null
cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DiskSweeper</string>
<key>CFBundleIdentifier</key><string>local.disksweeper</string>
<key>CFBundleName</key><string>Disk Sweeper</string>
<key>CFBundleIconFile</key><string>DiskSweeper</string>
<key>CFBundleIconName</key><string>DiskSweeper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
EOF
echo "Built $APP"
