#!/usr/bin/env bash
# Package a signed Limpid.app into a notarized .dmg ready for distribution.
#
# Prerequisites:
#   - A Developer ID signed Release build of Limpid.app
#   - create-dmg installed (brew install create-dmg)
#   - App-specific password stored as keychain profile "limpid-notarize-local"
#     (xcrun notarytool store-credentials limpid-notarize-local ...)
#
# Usage:
#   ./scripts/package-dmg.sh                     # auto-detect latest Release build
#   ./scripts/package-dmg.sh /path/to/Limpid.app # use a specific .app
#
# Output:
#   dist/Limpid-<version>.dmg  (notarized and stapled)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYCHAIN_PROFILE="limpid-notarize-local"
DIST_DIR="${REPO_ROOT}/dist"

# -- Locate the .app -----------------------------------------------------------

if [[ $# -ge 1 ]]; then
  APP_PATH="$1"
else
  # Default: the latest DerivedData Release build
  APP_PATH="$(ls -td "${HOME}"/Library/Developer/Xcode/DerivedData/Limpid-*/Build/Products/Release/Limpid.app 2>/dev/null | head -1)"
fi

if [[ -z "${APP_PATH:-}" || ! -d "${APP_PATH}" ]]; then
  echo "✗ Limpid.app not found." >&2
  echo "  Expected: Release build under DerivedData, or pass the path as an argument." >&2
  exit 1
fi

echo "✓ Using app: ${APP_PATH}"

# -- Verify the .app is properly signed and notarized -------------------------

echo "→ Verifying app signature..."
codesign --verify --strict --verbose=2 "${APP_PATH}" >/dev/null 2>&1 || {
  echo "✗ App signature verification failed." >&2
  exit 1
}

spctl_status="$(spctl --assess --type execute --verbose "${APP_PATH}" 2>&1 || true)"
if ! echo "${spctl_status}" | grep -q "accepted"; then
  echo "✗ App is not notarized or stapled." >&2
  echo "  spctl said: ${spctl_status}" >&2
  echo "  Run notarization on Limpid.app first." >&2
  exit 1
fi
echo "✓ App is notarized: $(echo "${spctl_status}" | head -1)"

# -- Read version from Info.plist ---------------------------------------------

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
echo "✓ Version: ${VERSION}"

# -- Build the dmg -------------------------------------------------------------

mkdir -p "${DIST_DIR}"
DMG_PATH="${DIST_DIR}/Limpid-${VERSION}.dmg"
rm -f "${DMG_PATH}"

echo "→ Creating dmg..."
# Stage LICENSE + THIRD-PARTY-NOTICES at the DMG root so license
# auditors and casual recipients can read the attribution without
# opening the .app bundle. The files also ride along inside the app
# (`Contents/Resources/`), but surfacing them at the root matches
# the convention most open-source Mac apps follow.
DMG_STAGING="$(mktemp -d)"
# `cp -R` preserves the .app bundle structure end-to-end; plain `cp`
# would refuse it as a directory. APFS clones the bytes on the same
# volume so the copy is effectively free.
cp -R "${APP_PATH}" "${DMG_STAGING}/"
[ -f "${REPO_ROOT}/LICENSE" ] && cp "${REPO_ROOT}/LICENSE" "${DMG_STAGING}/"
[ -f "${REPO_ROOT}/THIRD-PARTY-NOTICES" ] && cp "${REPO_ROOT}/THIRD-PARTY-NOTICES" "${DMG_STAGING}/"
create-dmg \
  --volname "Limpid ${VERSION}" \
  --window-size 540 380 \
  --icon-size 128 \
  --icon "Limpid.app" 140 190 \
  --app-drop-link 400 190 \
  --hide-extension "Limpid.app" \
  --no-internet-enable \
  --codesign "Developer ID Application" \
  "${DMG_PATH}" \
  "${DMG_STAGING}" \
  >/dev/null
rm -rf "${DMG_STAGING}"

echo "✓ dmg created: ${DMG_PATH}"

# -- Notarize the dmg ----------------------------------------------------------

echo "→ Submitting dmg for notarization (may take several minutes)..."
xcrun notarytool submit "${DMG_PATH}" \
  --keychain-profile "${KEYCHAIN_PROFILE}" \
  --wait

# -- Staple --------------------------------------------------------------------

echo "→ Stapling notarization ticket..."
xcrun stapler staple "${DMG_PATH}"

# -- Verify --------------------------------------------------------------------

echo "→ Verifying distribution..."
spctl --assess --type open --context context:primary-signature --verbose "${DMG_PATH}"

echo
echo "✅ Done: ${DMG_PATH}"
echo "   $(du -h "${DMG_PATH}" | awk '{print $1}')"
