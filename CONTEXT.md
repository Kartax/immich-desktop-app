# Immich Desktop

Immich Desktop presents a user’s remote Immich library through a macOS gallery and Finder integration.

## Language

**Asset**:
A photo or video in the Immich library that can appear in the gallery and be downloaded in its original form.
_Avoid_: Item, image

**Asset selection**:
A transient set of gallery Assets created only through tile selection controls, never by opening an Asset; it survives paging and detail viewing, but clears on a gallery timeline reset or window closure. Successfully downloaded or deleted Assets leave the selection, while failed and not-attempted Assets remain eligible for review and retry.
_Avoid_: Item selection, selected images

**Download batch**:
A cancellable, app-owned transfer of the selected assets’ original files into one user-chosen destination folder. Its asset selection is fixed while it runs, and it survives gallery-window closure.
_Avoid_: Export, asset download

**Asset deletion**:
Removal of an Asset from the Immich library, not merely from an album or gallery view. Any temporary retention in trash is governed by the Immich server’s policy.
_Avoid_: Album removal, local file deletion

**Deletion batch**:
A user-confirmed operation that deletes a fixed Asset selection from the Immich library and continues when the gallery window closes. Stopping leaves completed deletions intact; failed and not-attempted Assets can be retried only after another confirmation, while uncertain outcomes require reconciliation rather than automatic replay.
_Avoid_: Bulk removal, trash cleanup

**Asset upload**:
Transfer of a local photo or video file into the existing Immich library without changing its contents or embedded metadata or creating a separate upload-specific library or server folder hierarchy. Uploads accept individual files or multiple files together, not folders, and preserve local originals unless the user explicitly requests a Finder move.
_Avoid_: Import, sync

**Upload batch**:
A group of Asset uploads that continues when the gallery window closes, with progress and failures accessible from the menu-bar app. Files succeed or fail independently; temporary connection failures are retried automatically, while rejected files and permission failures require explicit action.
_Avoid_: Import job, upload session
