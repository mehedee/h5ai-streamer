# Myra 4.0.0

Myra 4 brings a redesigned native macOS interface, a more spacious player, and more reliable library refresh behavior.

- Native window controls, unified toolbar, selectable sidebar, and standard Settings tabs, switches and pickers.
- Consistent SF Symbols, system colors and Light/Dark appearance across the main and Settings windows.
- Separate playback timeline, comfortably spaced transport and volume groups, and compact layouts. Audio, subtitles, speed and video options remain available alongside episodes, repeat and markers.
- Immediate Refresh Library action, separate scheduled refresh, and clear paused, cancelled, failed and partial indexing states.
- Fix a startup dependency that could hold indexing while waiting for optional metadata credentials. Metadata Keychain reads no longer block the main UI thread.
- Preserve valid indexing batches and saved records for failed or cancelled scopes.
- Redesigned Home discovery, automatic category shelves, artwork fallbacks, and updated Ask Myra presentation and request handling.
- Refined experimental torrent Play/Download workflows. Networking remains opt-in; provider availability and buffering vary.

## Compatibility and distribution

Apple Silicon Mac, macOS 14 or later. This release was built and tested on macOS 27; a macOS 14 runtime and live provider networks were not available for full verification. Automated checks use isolated stores and mock AI providers; no paid cloud inference was used. Native synthetic-video playback and fullscreen transitions were exercised.

The app remains ad-hoc signed and is not Apple-notarized. Sparkle update assets are signed with Myra's existing release key. Personal library data and download paths are retained; no profile migration is introduced by these fixes.
