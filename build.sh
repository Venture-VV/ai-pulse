#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="AI Pulse"
BUNDLE_DIR="${APP_NAME}.app"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "🔨 Building ${APP_NAME}.app..."

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AIPulse</string>
    <key>CFBundleIdentifier</key>
    <string>com.lujunyi.aipulse.monitor</string>
    <key>CFBundleName</key>
    <string>AI Pulse</string>
    <key>CFBundleDisplayName</key>
    <string>AI Pulse 任务监控</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>AI Pulse 需要控制 System Events 以在您点击任务卡片时自动聚焦并置顶对应的 AI 软件窗口。</string>
</dict>
</plist>
EOF

swiftc \
    -O \
    -parse-as-library \
    Sources/Models.swift \
    Sources/PluginSystem.swift \
    Sources/WindowActivator.swift \
    Sources/TelemetryEngine.swift \
    Sources/Views.swift \
    Sources/AppMain.swift \
    -lsqlite3 \
    -framework AVFoundation \
    -framework Cocoa \
    -framework SwiftUI \
    -framework UserNotifications \
    -o "${MACOS_DIR}/AIPulse"

codesign --force --deep --sign - "${BUNDLE_DIR}"

echo "✅ Build complete: $(pwd)/${BUNDLE_DIR}"
