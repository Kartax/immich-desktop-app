# Immich Desktop

Immich Desktop presents a user’s remote Immich library through a macOS gallery and Finder integration.

## Language

**Asset**:
A photo or video in the Immich library that can appear in the gallery and be downloaded in its original form.
_Avoid_: Item, image

**Asset selection**:
A transient set of gallery assets created only through tile selection controls, never by opening an asset. It survives paging and detail viewing, but clears on a gallery timeline reset or window closure; successful downloads leave it while failed assets remain.
_Avoid_: Item selection, selected images

**Download batch**:
A cancellable, app-owned transfer of the selected assets’ original files into one user-chosen destination folder. Its asset selection is fixed while it runs, and it survives gallery-window closure.
_Avoid_: Export, asset download
