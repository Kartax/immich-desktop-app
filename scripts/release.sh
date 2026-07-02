#!/usr/bin/env bash
#
# Build, sign, notarize and package ImmichDesktop as a notarized .dmg for direct
# download (outside the Mac App Store).
#
# Prerequisites (one-time):
#   * Paid Apple Developer Program membership.
#   * A "Developer ID Application" certificate in your login keychain
#     (Xcode > Settings > Accounts > Manage Certificates).
#   * Notary credentials stored in a keychain profile named "NOTARY":
#       xcrun notarytool store-credentials "NOTARY" \
#         --apple-id <you@example.com> --team-id 8HAG9JU2ZK \
#         --password <app-specific-password>
#     (app-specific password from https://appleid.apple.com)
#
# Usage:
#   ./scripts/release.sh                                    # build + notarize a local .dmg only
#   ./scripts/release.sh v0.1.0                             # ...and publish it as a GitHub Release
#   ./scripts/release.sh v0.1.0 "Release description"       # ...with custom release notes
#
# Publishing uploads the .dmg to this repo's GitHub Releases (PUBLISH_REPO) via
# the GitHub CLI. Install + authenticate it once: `brew install gh && gh auth login`.
#
# Override the notary profile with NOTARY_PROFILE=<name> if you named it differently.

set -euo pipefail

# --- config ----------------------------------------------------------------
PROJECT="ImmichDesktop.xcodeproj"
SCHEME="ImmichDesktop"
APP_NAME="ImmichDesktop"
NOTARY_PROFILE="${NOTARY_PROFILE:-NOTARY}"
# This same repo hosts the download page (docs/ via Pages) and release binaries.
PUBLISH_REPO="${PUBLISH_REPO:-Kartax/immich-desktop-app}"
VERSION="${1:-}"   # e.g. v0.1.0 — when set, the .dmg is published as a Release
NOTES="${2:-}"     # optional release description; replaces the default notes text

# Resolve repo root up front (this script lives in scripts/) so all git and build
# commands run against the code repo regardless of the caller's cwd.
cd "$(dirname "$0")/.."

# Single source of truth: the version passed on the command line is also baked
# into the app (CFBundleShortVersionString), so project.yml's MARKETING_VERSION
# is just a fallback for local no-arg builds. The build number is a timestamp so
# it is always unique and monotonic.
VERSION_OVERRIDES=()
COMMIT=""
if [[ -n "$VERSION" ]]; then
  MARKETING="${VERSION#v}"                 # strip leading "v" -> 0.2.0
  BUILD_NUMBER="$(date +%Y%m%d%H%M)"
  VERSION_OVERRIDES=( "MARKETING_VERSION=$MARKETING" "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" )

  # --- pre-flight guards (fail fast, before the long build) ----------------
  # Ensure the source tag we create later actually matches the built .dmg.
  if [[ -n "$(git status --porcelain)" && "${ALLOW_DIRTY:-}" != "1" ]]; then
    echo "!! Working tree is dirty. Commit your changes first (so the source tag" >&2
    echo "   matches the built app), or set ALLOW_DIRTY=1 to override." >&2
    git status --short >&2
    exit 1
  fi
  # The version must not already be a tag here or on origin...
  if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
    echo "!! Tag $VERSION already exists locally. Pick a new version." >&2
    exit 1
  fi
  if [[ -n "$(git ls-remote --tags origin "refs/tags/$VERSION" 2>/dev/null)" ]]; then
    echo "!! Tag $VERSION already exists on origin. Pick a new version." >&2
    exit 1
  fi
  # ...nor an existing release in the public repo.
  if command -v gh >/dev/null 2>&1 \
     && gh release view "$VERSION" --repo "$PUBLISH_REPO" >/dev/null 2>&1; then
    echo "!! Release $VERSION already exists in $PUBLISH_REPO. Pick a new version." >&2
    exit 1
  fi
  COMMIT="$(git rev-parse --short HEAD)"
fi

BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/$APP_NAME.app"
DMG="$BUILD_DIR/$APP_NAME.dmg"
DMG_STAGE="$BUILD_DIR/dmg-stage"
DMG_ASSETS="$BUILD_DIR/dmg"   # generated background + volume icon

# create-dmg styles the install window (window size, background, icon layout,
# Applications drop link). Required tool, like xcodegen/gh.
command -v create-dmg >/dev/null 2>&1 || {
  echo "!! create-dmg not found — install with 'brew install create-dmg'." >&2
  exit 1
}

# --- 0. regenerate project (source list lives in pbxproj) ------------------
if command -v xcodegen >/dev/null 2>&1; then
  echo "==> xcodegen generate"
  xcodegen generate
fi

rm -rf "$ARCHIVE" "$EXPORT_DIR" "$DMG" "$DMG_STAGE" "$DMG_ASSETS"

# --- 1. archive (Release, Developer ID, Hardened Runtime) ------------------
echo "==> Archiving"
# -allowProvisioningUpdates lets xcodebuild create/download the Developer ID
# provisioning profiles required by the App Group entitlement (sandbox).
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" -allowProvisioningUpdates \
  ${VERSION_OVERRIDES[@]+"${VERSION_OVERRIDES[@]}"} archive

# --- 2. export signed .app -------------------------------------------------
echo "==> Exporting (developer-id)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions.plist -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates

# --- 3. build the styled .dmg ----------------------------------------------
echo "==> Building DMG"
mkdir -p "$DMG_STAGE" "$DMG_ASSETS"
# Stage ONLY the .app — create-dmg adds the Applications drop link itself
# (a manual `ln -s /Applications` would collide with --app-drop-link).
cp -R "$APP" "$DMG_STAGE/"

# 3a. Background: render @1x + @2x, then merge into a HiDPI .tiff so the window
#     stays crisp on Retina. tiffutil ships with macOS.
swift scripts/dmg/make-background.swift "$DMG_ASSETS"
tiffutil -cathidpicheck \
  "$DMG_ASSETS/background.png" "$DMG_ASSETS/background@2x.png" \
  -out "$DMG_ASSETS/background.tiff"

# 3b. Volume icon (replaces the generic disk icon in the window title bar) —
#     built from the app icon PNGs that already live in the asset catalog.
ICONSET="$DMG_ASSETS/VolumeIcon.iconset"
ICON_SRC="ImmichDesktop/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET"
cp "$ICON_SRC/icon_16.png"   "$ICONSET/icon_16x16.png"
cp "$ICON_SRC/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICON_SRC/icon_32.png"   "$ICONSET/icon_32x32.png"
cp "$ICON_SRC/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ICON_SRC/icon_128.png"  "$ICONSET/icon_128x128.png"
cp "$ICON_SRC/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$ICON_SRC/icon_256.png"  "$ICONSET/icon_256x256.png"
cp "$ICON_SRC/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$ICON_SRC/icon_512.png"  "$ICONSET/icon_512x512.png"
cp "$ICON_SRC/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$DMG_ASSETS/VolumeIcon.icns"

# 3c. Assemble the window. Icon x-positions (165 / 495) straddle the arrow band
#     drawn into the background by make-background.swift — keep them in sync.
create-dmg \
  --volname "$APP_NAME" \
  --background "$DMG_ASSETS/background.tiff" \
  --volicon "$DMG_ASSETS/VolumeIcon.icns" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 128 \
  --icon "$APP_NAME.app" 165 205 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 495 205 \
  "$DMG" "$DMG_STAGE"

# --- 4. notarize + staple --------------------------------------------------
echo "==> Submitting for notarization (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling ticket"
xcrun stapler staple "$DMG"

# --- 5. verify -------------------------------------------------------------
echo "==> Verifying"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -vvv "$DMG" || true

# --- 6. publish (optional) -------------------------------------------------
if [[ -n "$VERSION" ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "!! gh not found — install with 'brew install gh && gh auth login' to publish." >&2
    echo "   Built locally: $DMG"
    exit 1
  fi
  echo "==> Publishing $VERSION to $PUBLISH_REPO"
  # Source and release repo are now the same, so let `gh release create` create
  # the tag itself — at the exact built commit (--target). Doing it in one step
  # keeps the "tag only on a successful publish" property (a failed upload never
  # leaves an orphan tag) without a separate git tag/push that would collide.
  # A description passed as the second argument replaces the default install
  # blurb; the source-commit line is always appended.
  if [[ -n "$NOTES" ]]; then
    RELEASE_NOTES="$NOTES

Built from source commit \`$COMMIT\`."
  else
    RELEASE_NOTES="Immich Desktop $VERSION — notarized, macOS 14+. Download \`ImmichDesktop.dmg\`, move it to Applications, then enter your Immich server URL and API key from the menu bar.

Built from source commit \`$COMMIT\`."
  fi
  gh release create "$VERSION" "$DMG" \
    --repo "$PUBLISH_REPO" \
    --target "$(git rev-parse HEAD)" \
    --title "$VERSION" \
    --notes "$RELEASE_NOTES"
  echo "Published: https://github.com/$PUBLISH_REPO/releases/tag/$VERSION"

  # Sync the tag gh just created on the remote into the local clone.
  echo "==> Fetching tag $VERSION ($COMMIT) from origin"
  git fetch origin --tags
fi

echo
echo "Done: $DMG"
