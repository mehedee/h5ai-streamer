# Native torrent integration boundary (in progress)

The application is not connected to this boundary yet. Do not package it as a
finished torrent feature.

`VerifiedPieceBroker.hpp` owns the session's single alert-consumer thread and
shares verified piece reads across concurrent clients. It provides finite
timeouts, cancellation, and at most four pending reads (pieces up to 16 MB).
Returned buffers are caller-owned; this is not a total-process memory ceiling. Its owner must
keep the session/handle alive, stop/join HTTP workers, then destroy the broker.
All other alerts are delivered synchronously to an owner callback; alert
pointers must never be retained.

`HTTPRange.hpp` validates single bounded, open-ended, and suffix byte ranges.
Malformed, overflowing, multi-range and unsatisfiable requests must result in
HTTP 416.

`LoopbackStream.hpp` supplies a random 192-bit bearer-token route on IPv4
loopback, four workers and four queued connections, finite socket timeouts,
GET/HEAD and single ranges, selection-scoped access, and torrent-global
multi-file offset mapping. Disconnects, deselection and shutdown cancel
blocked verified reads. It never opens a library file or serves raw sparse
bytes. Normal playback and a seek to 30 seconds passed with bundled VLCKit
using the generated MPEG-4/AAC fixture and dummy audio/video output.

The app adapter, metadata/file selection, persistent engine resume state,
seeding/upload policy and distribution packaging are still pending.

The isolated fixture in `prototypes/torrent-engine/streaming-smoke.cpp` tests
these components with local-only peers. Nothing contacts public swarms.

API grounding: [libtorrent streaming](https://www.libtorrent.org/streaming.html)
and the vendored 2.0.11 public headers. The web documentation describes newer
APIs as well; installed-header compilation is the compatibility authority.
