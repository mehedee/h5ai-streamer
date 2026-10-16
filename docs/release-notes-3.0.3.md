# Myra 3.0.3 — Settings, indexing, and experimental torrents

- Settings are organized into six visible tabs: General, Library, Downloads,
  Playback, Discovery, and Torrents. The shared Save Settings action remains
  available across sections.
- Library indexing continues after an individual file or directory fails and
  records those failures. It commits each batch of 500 valid video records to
  the main SQLite index while scanning continues. Failed-path records are
  retained; stale-record reconciliation happens after a completed traversal.
  Cancellation keeps committed chunks and skips reconciliation. Database or
  storage failures still stop the refresh.
- Experimental torrent discovery and transfers are available in the app:
  curated open-movie entries, Internet Archive items with declared open
  licenses, optional Torznab sources, magnet and `.torrent` import, selected
  video playback through VLC, transfer controls, cache limits, and seeding
  preferences. Torrent networking is disabled until enabled for the current
  session; saved transfers restart paused. Peers and trackers can see the
  user's IP address, and source rights must be checked before use.
- Torrent identities, path validation, SQLite persistence, cache protection,
  native verified-piece streaming, and authenticated loopback HTTP are covered
  by isolated tests. The full helper-to-VLC torrent test requires a local
  fixture and is opt-in. The automated suite does not validate public swarms or
  provider availability.
- Existing HTTP library, downloads, and personal profile locations remain in
  place. Index schema migration backs up the previous index before migration.
- The updater and signed feed now use the canonical Myra GitHub repository URL.

Validation on macOS 27.0.1: `zsh Scripts/verify-update.sh` passed Swift format/lint,
project-file lint, the full package suite (158 tests, 12 skipped, zero failures),
the fixture-backed app-to-helper VLC playback/seek/restart test, Release build,
code-signature checks, and `hdiutil verify`. The isolated native streaming smoke
test also passed. No public swarm or live discovery provider was exercised.

Apple Silicon, macOS 14 or later. This personal build is ad-hoc signed, not
notarized. Install in Applications before updating; keep the previous app/DMG
for rollback. Existing categories, settings, downloads and personal library data
remain in their current locations.
