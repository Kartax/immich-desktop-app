# Keep download batches app-owned

Download batches belong to the menu-bar app rather than `GalleryView`. The gallery window is destroyed when closed while the app remains running, so app ownership lets an active batch continue and allows a reopened gallery to reconnect to its progress and result instead of forcing the window to remain open or silently cancelling user work. A result produced while the gallery is closed remains app state until the gallery reopens; it does not generate a macOS notification.
