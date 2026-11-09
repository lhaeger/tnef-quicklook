#!/bin/zsh
# Builds TNEF Preview and installs it into ~/Applications (or $INSTALL_DIR),
# then registers the Quick Look extension.
set -euo pipefail
cd "${0:A:h}/.."

if ! command -v xcodegen >/dev/null; then
    echo "xcodegen not found. Install it with: brew install xcodegen" >&2
    exit 1
fi

destination="${INSTALL_DIR:-$HOME/Applications}"
app="build/DerivedData/Build/Products/Release/TNEFPreview.app"

echo "Generating Xcode project…"
xcodegen generate --quiet

echo "Building…"
xcodebuild -project TNEFQuickLook.xcodeproj -scheme TNEFPreview -configuration Release -destination "generic/platform=macOS" \
    -derivedDataPath build/DerivedData -quiet build

echo "Installing to $destination…"
mkdir -p "$destination"
# ditto updates an existing copy in place
ditto "$app" "$destination/TNEFPreview.app"

# Launching the app once registers the extension with the system.
open "$destination/TNEFPreview.app"
sleep 2
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true

if pluginkit -m -p com.apple.quicklook.preview | grep -q 'io.github.lhaeger.TNEFPreview.QuickLook'; then
    echo "Done. Select a winmail.dat in Mail or Finder and press the spacebar."
else
    echo "Installed, but the extension is not registered yet." >&2
    echo "Check System Settings → General → Login Items & Extensions → Quick Look." >&2
    exit 1
fi
