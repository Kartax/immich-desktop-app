# AGENTS.md

## Build and validation

- `project.yml` is the source of truth; `ImmichDesktop.xcodeproj` is generated and ignored. Run `xcodegen generate` after changing `project.yml` or adding/removing Swift files.
- The runnable scheme is `ImmichDesktop`, which embeds `FileProviderExt`; both targets compile `Shared/`. Run the app scheme, not the extension.
- Normal unsigned compile check (there are no test targets):
  ```sh
  xcodebuild -project ImmichDesktop.xcodeproj -scheme ImmichDesktop \
    -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
  ```
- Running requires full Xcode and a signing team. If a CLI compile check reports an Xcode-license problem, prefix it with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`.
- Debug the extension with `log stream --level debug --predicate 'subsystem == "org.kartax.ImmichDesktop"'`; `log show` misses its non-persisted info-level output.

## Architecture and invariants

- `ImmichDesktop/` is an `LSUIElement` menu-bar app. `AppDelegate` owns the status item and AppKit-hosted SwiftUI windows; do not turn it into a conventional SwiftUI window app.
- `Shared/` is used by both processes. Keep app/extension configuration in `AppConfig`'s atomic JSON file in the App Group container, never `UserDefaults(suiteName:)`.
- Keep `AppConfig.domainIdentifier` as `ImmichDesktop`. Recover a stale provider with `DomainManager.activate(reset: true)` and `.removeAll`, not by changing the identifier.
- `ItemID` is a persisted virtual-tree protocol. Asset IDs are `asset|<parentRaw>|<assetId>` so one asset can appear under multiple folders; parse the asset form from the right because `parentRaw` can contain `|`.
- File Provider asset searches must retain `withExif: true`, or Immich omits file size and macOS can skip the download. Keep `FileProviderItem.itemVersion` derived from size plus filename so Finder refreshes changed metadata.
- Immich v3 search defaults are unsafe: non-album searches must send `visibility: "timeline"`; album searches use `albumIds` without that filter because album metadata no longer contains assets. Minimum supported server version is v1.135.0.
- `FileProviderExtension` must explicitly declare `NSFileProviderThumbnailing`, or Finder will not request thumbnails.
- The gallery must remain lazy: load one page at a time, deduplicate shifting-page asset IDs, and discard stale loads after a reset. Use thumbnail size `.preview`, never unsupported `.fullsize`.
- The menu bar and Finder sidebar must use the same monochrome SF Symbol (`camera.aperture`) in `AppDelegate` and `FileProviderExt/Info.plist`; the full-color app icon is separate.

## Site and releases

- `docs/` is a static GitHub Pages site with no build step; `.github/workflows/pages.yml` deploys it on qualifying pushes to `main`.
- When changing the app icon, copy its 512px and 1024px PNGs to `docs/logo.png` and `docs/logo@2x.png`. If the site URL changes, update the canonical references in `docs/index.html`, `docs/sitemap.xml`, and `docs/robots.txt`.
- `./scripts/release.sh` builds and notarizes a local DMG; `./scripts/release.sh vX.Y.Z ["notes"]` also publishes it to GitHub. It needs `create-dmg`, a Developer ID certificate, a `NOTARY` keychain profile (or `NOTARY_PROFILE` override), and authenticated `gh` to publish.
- Publishing requires a clean worktree by default (`ALLOW_DIRTY=1` overrides it); `gh release create` creates the release tag at the built commit.
- Do not create commits on the user's behalf.
