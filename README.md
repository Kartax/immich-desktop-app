# Immich Desktop (macOS File Provider)

[![Latest version](https://img.shields.io/github/v/release/Kartax/immich-desktop-app?label=version&color=4c8dff&labelColor=15181d&style=flat)](https://github.com/Kartax/immich-desktop-app/releases/latest)
[![Release date](https://img.shields.io/github/release-date/Kartax/immich-desktop-app?label=released&color=4c8dff&labelColor=15181d&style=flat)](https://github.com/Kartax/immich-desktop-app/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/Kartax/immich-desktop-app/total?label=downloads&color=4c8dff&labelColor=15181d&style=flat)](https://github.com/Kartax/immich-desktop-app/releases)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-4c8dff?labelColor=15181d&style=flat)](https://kartax.github.io/immich-desktop-app/)

Exposes a self-hosted **Immich** server as a drive in macOS. Immich shows up in the
**Finder sidebar** and in every **file open/upload dialog** (e.g. when a website asks
you to attach a file). Albums and a date-based timeline appear as folders; the
original files are downloaded **on demand**, only when you actually open or select
them.

Add original photos and videos through gallery drops or Finder's **All Photos**
entry point. Finder does not allow editing or deleting existing library files.
The gallery can optionally delete Assets after you enable **Allow deletions** in Settings.

**Download & info:** https://kartax.github.io/immich-desktop-app/ — a notarized
`.dmg` for macOS 14+. This repo holds everything: the source, the download page
(`docs/`, served via GitHub Pages) and the release binaries (GitHub Releases).

## What it does

- Browse your Immich library straight from Finder and file pickers — no manual
  download-then-upload dance.
- On-demand: thumbnails and originals are fetched from the server only when needed.
- Several ways to navigate (each view can be toggled in the settings):
  - **All Photos** → Year → Month → assets (Immich timeline)
  - one folder per **album**
  - **Persons** and **Places** (country → city)
- Albums, person folders, and city folders can each be independently organized into
  **Year → Month** folders. Choose **Never**, **500 files or more**, or **Always** for
  each view in the settings; the 500-file mode is the default.
- A built-in **Gallery window** (*View Gallery* in the menu bar): skim the whole
  timeline newest-first, click any photo or video to view it large (videos stream
  from the server), and jump straight to any year/month. Only what's on screen is
  fetched, so it stays fast on huge libraries.
- Select one or more gallery Assets to **Download** their originals to a folder,
  or **Delete** them from the Immich library when deletion is enabled. Result banners
  disappear after five seconds, or immediately using the **×** at the top right.
- **Copy** gallery Assets with the button immediately left of Download, a tile's
  right-click menu, or **⌘C**. The enlarged view also has Copy and **⌘C** for its
  displayed Asset. Copy preserves the selection and prepares original files for
  pasting into Finder folders or compatible document and mail apps.
- Drop one or multiple image/video files onto the gallery, or drop/copy/move-paste
  them into Finder's **All Photos** entry point to upload into your existing library.
  See the validation limits below before relying on Finder moves.

## Finder structure

```
Immich/
├─ All Photos/
│  └─ 2024/
│     └─ 03 March/
│        └─ IMG_1234.jpg ...
├─ Persons/
│  └─ <Person name>/[<Year>/<Month>/] ...
├─ Places/
│  └─ <Country>/<City>/[<Year>/<Month>/] ...
└─ <Album name>/
   └─ [<Year>/<Month>/] IMG_5678.jpg ...
```

`All Photos` uses the Immich timeline (`/timeline/buckets`) for the year/month tree;
a month's assets are loaded via `POST /search/metadata` (date range, paginated,
`withExif: true` so file sizes are known).

The optional bracketed levels follow the grouping mode selected independently for
Albums, Persons, and Places. Assets without a usable date appear directly inside a
single **Unknown Date** folder when grouping is active.

### Uploading originals

Drop one or multiple standalone image/video files into the gallery or into the
**All Photos** entry point in Finder; Finder copy/paste and move-paste use the same
addition-only destination. Other folders, including date folders and albums, do
not accept uploads. Folders and non-media files are rejected. Server-supported RAW
files are accepted; Live Photo pairing and separate XMP sidecars are not supported.

Uploads send originals unchanged, preserving embedded metadata without resizing,
transcoding, stripping location, overriding dates, or creating albums. Immich's
normal storage rules apply. Completed Assets belong in their natural date folders,
not a separate Uploads hierarchy. Gallery drops and Finder copies keep local
originals. Explicit Finder moves are intended to remove the source only after
server confirmation, but **native Finder source-unlink timing and date-folder
reparenting remain unverified pending the user's runtime validation**. This is not
a source-preservation guarantee; use copies until that behavior is validated.

Existing non-trashed duplicates count as **Already in library**. Trashed duplicates
need attention and are not automatically restored or accepted as successful moves.
Gallery uploads continue when its window closes, with progress, cancellation, and
per-file failures available from the menu-bar app. Retry failed files explicitly;
temporary transfer failures are retried automatically. Cancellation can leave an
in-flight request completed on the server and never deletes completed uploads.
Successful gallery upload results disappear after two seconds; failures and cancelled
uploads remain available for review. Visible gallery tiles retry thumbnails while
Immich processes newly uploaded originals, without needing to reopen the gallery.
No app-managed persistent upload queue or recovery copies are retained; interrupted
gallery uploads do not resume after relaunch. Finder owns its staging and retries.
Multipart encoding uses a temporary transport file, removed when the transfer ends;
large videos therefore require additional free local disk space during upload.
Stop or wait for unfinished gallery and Finder transfers before changing the server,
API key, grouping hierarchy, or removing the Finder domain.

### Copying Assets from the gallery

Copy prepares all requested originals before replacing the clipboard. Progress and
**Cancel** remain available if you close and reopen the gallery; other gallery
transfers and deletion are unavailable during preparation. Failure or cancellation
leaves the previous clipboard unchanged. If you copy something else while originals
are being prepared, that newer clipboard content wins.
Successful copies finish silently, without a confirmation banner; failures and
cancellation still display a dismissible message.

Right-clicking a selected Asset copies the selection; right-clicking an unselected
Asset copies only that Asset without changing the selection. Multiple Assets use
gallery display order. Duplicate filenames receive suffixes such as `photo (2).jpg`;
the original file contents are unchanged.

Photos also offer a decoded image representation where macOS supports it. The
receiving application decides whether to insert images or attach files, which media
formats it accepts, and how it handles multiple Assets. Universal paste support is
not guaranteed, especially for videos and RAW/HEIC files.

Originals use temporary local staging space, retained while backing the current
clipboard and removed after it is replaced. There is no persistent copy cache or
guarantee that copied Assets remain pasteable after quitting Immich Desktop.

### Deleting Assets from the gallery

**Allow deletions** is off by default, including after an upgrade. Enable it in
Settings and grant the API key the optional **`asset.delete`** permission. Changing
the server or API key turns the setting off again. Browsing and downloading do not
require deletion permission.

Select Assets using the gallery's selection controls, then choose **Delete**.
Confirm the selection before any request is sent. Deletion affects the underlying
Asset throughout the Immich library, including its appearances in albums; it is
not just removal from the current view. The app uses normal deletion, not forced
permanent deletion. Trash retention is controlled by your server: if trash is
disabled, deletion can be permanent. Restore through Immich where available;
the desktop app has no Undo or trash browser.

Deletion continues if you close the gallery. **Stop** lets the current request
finish and leaves the remaining Assets unattempted; it does not restore completed
deletions. Results distinguish deleted, failed, not-attempted, and uncertain Assets.
The result disappears after five seconds, or you can close it with **×** before
starting another download or deletion. Failed and not-attempted Assets can be
selected again, but every retry requires confirmation. Automatic dismissal pauses
while a retry confirmation is open.
If a response is lost or the app is interrupted, uncertain deletions are never
automatically replayed. Check Immich if the app cannot establish the outcome.

Finder deletion remains unavailable even when gallery deletion is enabled; its
upload entry point permits additions only. Confirmed deletions are propagated to
known Finder appearances, including grouped folders; Finder may take time to catch
up while its extension is unavailable. Separately downloaded files are not deleted,
and this is not secure erasure of local caches.

## Project layout

| Path | Purpose |
|------|---------|
| `ImmichDesktop/` | Container app (menu bar): settings, File Provider domain lifecycle, built-in gallery window |
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
   permissions: `album.read`, `asset.read`, `asset.download`, `asset.view` — all four
   (`asset.view` gates the thumbnail endpoint, so grid previews need it) — plus
   `person.read` for the Persons view.
   Optionally grant **`asset.upload`** for uploads and **`asset.delete`** for gallery
   deletion; existing read-only keys remain valid for browsing and downloading.
   No additional key-management permission is required. Upload requests adapt the
   required multipart fields to pre-v3 and v3 servers; checksum checks use `asset.upload`.

The minimum supported Immich server version is **v1.135.0**. On servers that expose
the current key's permissions, Settings shows whether `asset.delete` is missing
and disables the Delete action when it is.

Older supported servers, including v1.135.0, do not consistently enforce
`asset.delete` on the deletion endpoint. Omitting that scope is therefore not a
universal server-side read-only guarantee. **Allow deletions** controls this app's
gallery action; it does not change what the API key can do in other clients.

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
   API key → **Test Connection** → **Save & Activate**. The window closes
   automatically after activation.
4. Open Finder → **Immich** appears under *Locations* in the sidebar.

The app runs as a **menu bar item** (no Dock icon, `LSUIElement`). The menu bar icon
shows it's running and offers *View Gallery* (the built-in gallery window),
*Open Settings…* (reopen the settings window) and *Quit Immich Desktop*. Finder
remains mounted when the app quits so macOS can retain queued transfers and
continue them independently. Launching the app registers the domain if needed.
Quitting with gallery uploads offers to keep uploading or stop unfinished work.
(Stopping the app from Xcode does not run the quit path.)

Icons: `AppIcon` in `ImmichDesktop/Assets.xcassets` is the full-color app icon; the
menu bar and the Finder sidebar both use the SF Symbol `camera.aperture` (a template
image that adapts to light/dark), kept in sync between the status item and the
extension's `Info.plist`.

To compile-check from the command line without signing:

```sh
xcodebuild -project ImmichDesktop.xcodeproj -scheme ImmichDesktop \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

### Clean up development app copies

Repeated builds can leave duplicate ImmichDesktop icons in Launchpad / Apps.
Preview the registered copies and disposable build artifacts first:

```sh
./scripts/clean-dev-apps.sh
./scripts/clean-dev-apps.sh --apply
# Unregister copies without deleting build artifacts instead:
./scripts/clean-dev-apps.sh --apply --keep-build-artifacts
```

`--apply` unregisters copies, deletes registered bundles under `build/`, `tmp/`
and `.xcarchive` (removing the whole archive), clears matching ImmichDesktop
DerivedData, and restarts Dock / Apps to refresh their icon lists.
`/Applications/ImmichDesktop.app` is never touched. This is development-build
cleanup, not an uninstall or a File Provider domain reset.

## Notes for a free Apple ID

- Apps signed with a **free** Apple ID only run for **7 days**; after that, open the
  project in Xcode and press ⌘R once to re-sign. The File Provider keeps working
  while Xcode is closed — the system launches the extension on demand — but the
  signature expiry still applies. A paid Apple Developer account signs for 1 year.
- The app reaches the server over plain HTTP / a private CA, so both `Info.plist`
  files carry an **App Transport Security** exception
  (`NSAllowsArbitraryLoads` + `NSAllowsLocalNetworking`).

## Troubleshooting

- **Finder shows "signed out" / the folder stays empty:** click *Save & Activate*
  again. Activation removes any stale domain and registers a fresh one. Live logs:
  `log stream --predicate 'subsystem == "org.kartax.ImmichDesktop"'`.
- **Files show as 0 KB and won't open:** the asset size was missing — make sure the
  search request sends `withExif: true` (already handled in `ImmichClient`).
- **No grid thumbnails:** the principal class must declare
  `NSFileProviderThumbnailing` conformance (already handled) and the API key must be
  able to read thumbnails.

## Known limitations

- Finder supports additions through **All Photos** only. Renaming, moving, editing,
  or deleting existing library files through Finder is not supported.
- Native Finder move source-unlink timing and natural-date reparenting have not
  been validated against a real server. Implementation is authorized ahead of that
  runtime validation; do not treat the intended move behavior as a guarantee.
- Configuration changes and domain removal check active transfers and Finder's
  pending-upload set. macOS delays and limits that set and omits initial transfers;
  a system-queued upload not yet reported to the provider may be invisible to the
  guard. Resolve Finder transfer errors and finish queued work before resetting.
- Gallery-initiated deletions are reconciled with Finder. Changes made through
  other Immich clients are not continuously synchronized and may require folder
  re-enumeration.
- Trash retention and permissions depend on the Immich server. Gallery deletion
  does not guarantee a recovery period or removal of an external-library original
  from its underlying storage.
