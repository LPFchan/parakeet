#!/bin/sh
# Builds build/Parakeet.app (Apple silicon, macOS 15+). The version comes
# from the latest vX.Y.Z tag; the build number is the commit count.
# Signs with $SIGN_IDENTITY, else a Developer ID certificate, else the
# "Parakeet Self-Signed" certificate (see README), else ad-hoc.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
app="$root/build/Parakeet.app"
version=$(git -C "$root" describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//')
version=${version:-0.0.0}
build=$(git -C "$root" rev-list --count HEAD)
identities=$(security find-identity -p codesigning)
identity=${SIGN_IDENTITY:-$(echo "$identities" | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}
if [ -z "$identity" ] && echo "$identities" | grep -q '"Parakeet Self-Signed"'; then identity="Parakeet Self-Signed"; fi

swift build -c release --arch arm64 --package-path "$root/app"
bin=$(swift build -c release --arch arm64 --package-path "$root/app" --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
cp "$bin/Parakeet" "$app/Contents/MacOS/Parakeet"
ditto "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
# PermissionFlow's strings, where its lookup finds them.
ditto "$bin/PermissionFlow_PermissionFlow.bundle" "$app/Contents/Resources/PermissionFlow_PermissionFlow.bundle"
cp "$root/app/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
# License notices for Parakeet and the libraries built into it.
licenses="$app/Contents/Resources/Licenses"
checkouts="$root/app/.build/checkouts"
mkdir -p "$licenses"
cp "$root/LICENSE" "$licenses/Parakeet.txt"
cp "$checkouts/FluidAudio/LICENSE" "$licenses/FluidAudio.txt"
cp "$checkouts/FluidAudio/ThirdPartyLicenses/"* "$licenses/"
cp "$checkouts/Sparkle/LICENSE" "$licenses/Sparkle.txt"
cp "$checkouts/PermissionFlow/LICENSE" "$licenses/PermissionFlow.txt"
# Translations: String Catalogs → <lang>.lproj/*.strings. English is the source,
# but still needs its own folder so macOS counts it as a supported language.
for catalog in Localizable InfoPlist; do
    xcrun xcstringstool compile "$root/app/Resources/$catalog.xcstrings" --output-directory "$app/Contents/Resources"
done
mkdir -p "$app/Contents/Resources/en.lproj"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>plus.lost.parakeet</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleName</key><string>Parakeet</string>
  <key>CFBundleDisplayName</key><string>Parakeet</string>
  <key>CFBundleExecutable</key><string>Parakeet</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 LPFchan</string>
  <key>NSAudioCaptureUsageDescription</key><string>Parakeet listens to system audio to show live captions. Audio never leaves this Mac.</string>
  <key>SUFeedURL</key><string>https://parakeet.lost.plus/appcast.xml</string>
  <key>SUPublicEDKey</key><string>bQtN+t2++IUhG6RJr/kCBTkEHRORYjUZnCcwplEwn+A=</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

if [ -n "$identity" ]; then
    # Inside out, as Sparkle's docs describe. A stable certificate keeps the
    # app's identity across updates, so macOS remembers the audio permission.
    # Notarization (Developer ID only) needs the hardened runtime; without an
    # Apple team ID it would refuse to load Sparkle.framework.
    case $identity in Developer\ ID*) flags="--timestamp --options runtime" ;; *) flags= ;; esac
    sign() { codesign --force $flags --sign "$identity" "$@"; }
    fw="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
    sign "$fw/XPCServices/Installer.xpc" "$fw/XPCServices/Downloader.xpc" "$fw/Autoupdate" "$fw/Updater.app"
    sign "$app/Contents/Frameworks/Sparkle.framework"
    sign "$app"
    echo "signed: $identity"
else
    codesign --force --deep --sign - "$app"
    echo "signed: ad-hoc (macOS forgets the audio permission on every rebuild)"
fi
echo "$app ($version, build $build)"
