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
# ".noindex" keeps Spotlight, and with it LaunchServices, away from the build output.
# Otherwise the built copy registers as a second extension with the same identifier.
derived_data="build/DerivedData.noindex"
app="$derived_data/Build/Products/Release/TNEFPreview.app"
appex="Contents/PlugIns/TNEFPreviewExtension.appex"

echo "Generating Xcode project…"
xcodegen generate --quiet

echo "Building…"
xcodebuild -project TNEFQuickLook.xcodeproj -scheme TNEFPreview -configuration Release -destination "generic/platform=macOS" \
    -derivedDataPath "$derived_data" -quiet build

echo "Installing to $destination…"
mkdir -p "$destination"
# ditto updates an existing copy in place
ditto "$app" "$destination/TNEFPreview.app"

# Launching the app once registers the extension with the system.
open "$destination/TNEFPreview.app"
pluginkit -a "$destination/TNEFPreview.app/$appex"
sleep 2

# Quick Look keeps running extension and viewer processes; restart them so the
# new build is used right away.
pkill -f TNEFPreviewExtension || true
killall QuickLookUIService 2>/dev/null || true
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true

registrations=$(pluginkit -m -p com.apple.quicklook.preview -i io.github.lhaeger.TNEFPreview.QuickLook -v | grep -c 'TNEFPreviewExtension.appex' || true)
if [[ "$registrations" -gt 1 ]]; then
    echo "Warning: $registrations copies of the extension are registered; Quick Look may pick the wrong one:" >&2
    pluginkit -m -v -i io.github.lhaeger.TNEFPreview.QuickLook >&2
    echo "Unregister the others with: pluginkit -r <path to .appex>" >&2
fi

if pluginkit -m -p com.apple.quicklook.preview | grep -q 'io.github.lhaeger.TNEFPreview.QuickLook'; then
    echo "Done. Select a winmail.dat in Mail or Finder and press the spacebar."
else
    echo "Installed, but the extension is not registered yet." >&2
    echo "Check System Settings → General → Login Items & Extensions → Quick Look." >&2
    exit 1
fi
