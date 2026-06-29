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
#   ./scripts/release.sh              # build + notarize a local .dmg only
#   ./scripts/release.sh v0.1.0       # ...and publish it as a GitHub Release
#
# Publishing uploads the .dmg to the public distribution repo (PUBLISH_REPO) via
# the GitHub CLI. Install + authenticate it once: `brew install gh && gh auth login`.
#
# Override the notary profile with NOTARY_PROFILE=<name> if you named it differently.

set -euo pipefail

# --- config ----------------------------------------------------------------
PROJECT="ImmichDesktop.xcodeproj"
SCHEME="ImmichDesktop"
APP_NAME="ImmichDesktop"
NOTARY_PROFILE="${NOTARY_PROFILE:-NOTARY}"
# Public repo that hosts the download page and release binaries (Option B).
PUBLISH_REPO="${PUBLISH_REPO:-Kartax/immich-desktop-app-public}"
VERSION="${1:-}"   # e.g. v0.1.0 — when set, the .dmg is published as a Release

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

# --- 0. regenerate project (source list lives in pbxproj) ------------------
if command -v xcodegen >/dev/null 2>&1; then
  echo "==> xcodegen generate"
  xcodegen generate
fi

rm -rf "$ARCHIVE" "$EXPORT_DIR" "$DMG" "$DMG_STAGE"

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

# --- 3. build the .dmg -----------------------------------------------------
echo "==> Building DMG"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE" \
  -ov -format UDZO "$DMG"

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
  gh release create "$VERSION" "$DMG" \
    --repo "$PUBLISH_REPO" \
    --title "$VERSION" \
    --notes "Immich Desktop $VERSION — notarized, macOS 14+. Download \`ImmichDesktop.dmg\`, move it to Applications, then enter your Immich server URL and API key from the menu bar.

Built from source commit \`$COMMIT\` (private repo)."
  echo "Published: https://github.com/$PUBLISH_REPO/releases/tag/$VERSION"

  # Tag the exact built source in the code repo and push it. Done last so a failed
  # build/upload never leaves an orphan tag. HEAD == built source (clean tree was
  # enforced above; build/ is gitignored).
  echo "==> Tagging source $VERSION ($COMMIT) and pushing to origin"
  git tag -a "$VERSION" -m "Release $VERSION"
  git push origin "$VERSION"
fi

echo
echo "Done: $DMG"
