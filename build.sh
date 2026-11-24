#!/bin/zsh
# Builds "build/Space Overview.app".
set -euo pipefail
cd "${0:A:h}"
export PATH="$HOME/.cargo/bin:$PATH"
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}" MACOSX_DEPLOYMENT_TARGET=14.0
# Keep local paths out of the app.
export RUSTFLAGS="--remap-path-prefix=$HOME=~ ${RUSTFLAGS:-}"
cargo build --release --lib --manifest-path core/Cargo.toml
A="build/Space Overview.app/Contents"
mkdir -p "$A/MacOS" "$A/Resources"
cp app/AppIcon.icns "$A/Resources/"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -import-objc-header core/include/space_core.h \
  app/*.swift core/target/release/libspace_core.a -o "$A/MacOS/SpaceOverview"
cat > "$A/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SpaceOverview</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>local.space-overview</string>
<key>CFBundleName</key><string>Space Overview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
P
strip -S -x "$A/MacOS/SpaceOverview" 2>/dev/null
codesign --force --sign - "build/Space Overview.app"
