# Immich Desktop (macOS File Provider)

Exposes a self-hosted **Immich** server as a drive in macOS. Immich shows up in the
**Finder sidebar** and in every **file open/upload dialog** (e.g. when a website asks
you to attach a file). Albums and a date-based timeline appear as folders; the
original files are downloaded **on demand**, only when you actually open or select
them.

Read-only: the app never modifies anything on the server.

## What it does

- Browse your Immich library straight from Finder and file pickers — no manual
  download-then-upload dance.
- On-demand: thumbnails and originals are fetched from the server only when needed.
- Two ways to navigate:
  - **All Photos** → Year → Month → assets (Immich timeline)
  - one folder per **album**

## Finder structure

```
Immich/
├─ All Photos/
│  └─ 2024/
│     └─ 03 März/
│        └─ IMG_1234.jpg ...
└─ <Album name>/
   └─ IMG_5678.jpg ...
```

`All Photos` uses the Immich timeline (`/timeline/buckets`) for the year/month tree;
a month's assets are loaded via `POST /search/metadata` (date range, paginated,
`withExif: true` so file sizes are known).

## Project layout

| Path | Purpose |
|------|---------|
| `ImmichDesktop/` | Container app (SwiftUI): enter server URL + API key, activate the domain |
| `FileProviderExt/` | File Provider extension (`NSFileProviderReplicatedExtension` + `NSFileProviderThumbnailing`) |
| `Shared/` | Immich API client, models, shared config |
| `project.yml` | XcodeGen project definition |

Config is shared between the app and the extension via a JSON file in the App Group
container (`group.org.kartax.ImmichDesktop`) — deliberately **not** `UserDefaults`,
which is unreliable for App Groups on macOS.

## Prerequisites

1. **Full Xcode** (from the App Store). The Command Line Tools alone cannot build or
   sign the extension.
2. **XcodeGen**: `brew install xcodegen`
3. An **Immich API key**: Immich → *Account Settings → API Keys*. Required
   permissions: `album.read`, `asset.read`, `asset.download` (the thumbnail endpoint
   also worked without `asset.view` on the test server; add it if grid previews fail).

## Build & run

```sh
cd immich-desktop-app
xcodegen generate          # creates ImmichDesktop.xcodeproj from project.yml
open ImmichDesktop.xcodeproj
```

In Xcode:

1. Select both targets (`ImmichDesktop`, `FileProviderExt`) →
   *Signing & Capabilities* → set **Team** to your Apple ID / Personal Team.
   Both targets must use the **same team** and the same App Group
   `group.org.kartax.ImmichDesktop`.
2. Pick the `ImmichDesktop` scheme and **My Mac**, then **Run** (⌘R).
3. In the app window enter the server URL (e.g. `https://immich.example.org`) and the
   API key → **Verbindung testen** (test) → **Speichern & aktivieren** (save &
   activate). The window closes automatically after activation.
4. Open Finder → **Immich** appears under *Locations* in the sidebar.

The app runs as a **menu bar item** (no Dock icon, `LSUIElement`). The menu bar icon
shows it's running and offers *Open Settings…* (reopen the settings window) and
*Quit Immich Desktop*. The Finder integration is tied to the app: **Quit removes the
Immich domain** (it disappears from Finder), and **launching the app re-adds it**
automatically if it was configured before. (Stopping the app from Xcode does not run
the quit path, so the domain stays until the next launch re-syncs it.)

Icons live in `ImmichDesktop/Assets.xcassets`: `AppIcon` (also what Finder shows for
the provider) and `MenuBarIcon` (a template image that adapts to light/dark menu bars).

To compile-check from the command line without signing:

```sh
xcodebuild -project ImmichDesktop.xcodeproj -scheme ImmichDesktop \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

## Notes for a free Apple ID

- Apps signed with a **free** Apple ID only run for **7 days**; after that, open the
  project in Xcode and press ⌘R once to re-sign. The File Provider keeps working
  while Xcode is closed — the system launches the extension on demand — but the
  signature expiry still applies. A paid Apple Developer account signs for 1 year.
- The app reaches the server over plain HTTP / a private CA, so both `Info.plist`
  files carry an **App Transport Security** exception
  (`NSAllowsArbitraryLoads` + `NSAllowsLocalNetworking`).

## Troubleshooting

- **Finder shows "signed out" / the folder stays empty:** click *Speichern &
  aktivieren* again. Activation removes any stale domain and registers a fresh one
  (identifier `immich-v2`). Live logs:
  `log stream --predicate 'subsystem == "org.kartax.ImmichDesktop"'`.
- **Files show as 0 KB and won't open:** the asset size was missing — make sure the
  search request sends `withExif: true` (already handled in `ImmichClient`).
- **No grid thumbnails:** the principal class must declare
  `NSFileProviderThumbnailing` conformance (already handled) and the API key must be
  able to read thumbnails.

## Known limitations

- No change tracking (sync anchors): newly added or deleted assets appear only after
  the folder is re-enumerated.
- Read-only — uploads back to Immich are not supported.
