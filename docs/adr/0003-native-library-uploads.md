---
status: accepted
---

# Upload into the existing library through gallery and Finder

Gallery drops and Finder drops/copy/move-paste into All Photos upload original files into the authenticated user's existing Immich library, using the server's normal storage rules and the assets' natural dates rather than introducing an upload-specific folder hierarchy. Gallery work belongs to the menu-bar app, while Finder work follows the native File Provider lifecycle; neither adds an app-managed persistent upload queue or retained recovery copies. Finder permits additions through All Photos only, retaining the existing restrictions on all other folders and on mutations of existing assets; this supersedes ADR 0002's blanket read-only Finder boundary without enabling Finder deletion.

## Agreed behavior

- Accept one or multiple standalone image/video files, including server-supported RAW formats. Reject folders and non-media files explicitly. Do not pair Live Photo components or attach separate XMP sidecars.
- Transfer originals unchanged, including embedded metadata. Do not resize, transcode, strip location, override capture dates, or create albums.
- Gallery drops and Finder copies preserve local originals. Explicit Finder moves are intended to remove sources only after server confirmation; macOS owns source removal. Actual source-unlink timing remains unverified pending the user's native runtime validation, not an established guarantee.
- All Photos is an upload entry point; completed assets appear in their natural date folders rather than remaining as loose files at its root. File Provider creation/reparenting behavior for this entry point remains unverified pending the user's native runtime validation.
- Refresh affected gallery and Finder data after completion without automatically navigating to the uploaded date, resetting browsing position, or clearing gallery selection.
- Existing non-trashed duplicates count as Already in library, not failures or additional assets. Trashed duplicates require attention: do not restore them automatically or treat them as successful moves.
- Gallery uploads continue when the gallery closes. Progress and per-file failures remain accessible from the menu-bar app.
- Gallery quit with unfinished work offers Keep uploading or Quit and stop uploads. Completed assets remain; unfinished gallery work does not resume after relaunch. Finder transfers may continue independently of the app, with macOS-managed local content and retry behavior.
- Retry temporary outages automatically; surface authentication/permission errors and rejected files for explicit action. Retry uncertain transfers using checksum-based duplicate handling, without creating additional assets.
- Files succeed or fail independently. Continue other files after a failure and offer retry of failed files only. If an original source becomes unavailable, report the failure and require the user to drop it again.
- Cancellation stops pending work and interrupts active work where possible, without deleting completed assets. An in-flight request can still complete on the server.
- Block server/credential changes and provider resets while gallery or Finder transfers remain unfinished. Never redirect queued files to another connection or destroy pending Finder content through a domain reset.
- Upload permission is optional: existing read-only keys remain valid for browsing and downloading. Uploads require the server's upload permission (`asset.upload` where exposed); the client handles old/new upload and checksum scopes without requiring additional key-management privileges. The minimum supported server remains v1.135.0.
- Configuration/domain changes use cross-process exclusion for active transfers and inspect Finder's pending set for known unfinished/error uploads before mutation. The pending set is delayed, bounded, and omits initial transfers, so it cannot prove the absence of a system-queued initial creation before the provider callback. This residual native lifecycle limitation remains part of runtime validation, not a complete source-preservation guarantee.
- Multipart encoding uses a bounded-memory temporary transport file that is removed on normal success, error, or cancellation; this is not a recovery copy or restart queue. Large videos require temporary free disk space. Finder remains mounted on app quit so system-owned queued work is not destroyed.
- Integrated app/extension compilation and the existing 18-test download/deletion suite pass. A disposable local HTTP smoke exercised byte-identical original transfer, pre-v3/v3 payloads, duplicate reuse, trashed-duplicate rejection, folder rejection, and date/size metadata; native Finder and real-server behavior remain user validation tasks.

## Confirmation and verification boundary

The user accepted this design and explicitly overrode the original pre-implementation native runtime safety gate: continue implementation now; the user will validate native Finder behavior later. Real-server Finder validation is not a prerequisite for implementation. This authorization does not prove source protection or All Photos date-folder reparenting and does not permit silently adding an Uploads folder, changing dates, weakening source protection, or reducing scope. This ADR records the accepted contract, not a claim that implementation is integrated or verified. Integration must preserve the existing supported server range and update ADR 0002 and user-facing documentation. Actual gallery drops and Finder copy/move-paste against a real server, especially source-unlink timing and natural-date reparenting, remain validation work for the user.
