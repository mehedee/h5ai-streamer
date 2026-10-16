# Native torrent feasibility prototype

This isolated test is not shipped or integrated into Myra. It creates synthetic
bytes (not a playable MP4) and two libtorrent sessions bound to loopback.
DHT, local discovery, UPnP, NAT-PMP, uTP and public trackers are disabled.

The test checks magnet metadata resolution without starting payload downloads,
deadline-based requests at the beginning/end/middle, hash-verified byte reads,
cached seeking, resume-data round trips, pause/resume, malformed magnets and
relative path rejection.

The optional --serve mode uses a generated MP4 to test loopback HTTP Range
delivery to Myra's bundled VLCKit. Native playback and a seek to 30 seconds
passed while required pieces were still missing. The smoke test runs with
dummy audio/video output: it does not verify Myra's visible player interface.

The fixture also verifies the app-facing native boundary in
`Native/TorrentEngine`: eight concurrent verified readers, authenticated
loopback GET/HEAD, strict single ranges, multi-file offsets, four concurrent
HTTP clients, seeking while abandoned clients remain open, cancellation,
timeout and recovery after pause. The loopback fixture uses a one-second
peer reconnect delay; libtorrent's default is 60 seconds. This test setting
does not change the released app.

The optional `--serve` now uses that bounded concurrent transport rather than
the original single-client prototype. It prints a temporary stream URL and
stops when its owner sends a newline to stdin. Never expose it externally.

This does **not** prove full restart recovery, seeding preferences, end-to-end
cache cleanup, discovery integration or release compatibility. Independent
Swift cache/database tests do not prove the feature is connected to the UI.

Prototype dependencies: libtorrent 2.0.11, Boost 1.85.0, source-built OpenSSL 3.6.5 static
archives. Production dependency versions, complete source checksums, license
bundling and macOS 14 compatibility must be settled before shipping.
Sources and build outputs stay under the ignored .build/torrent-prototype folder.

Boost archive SHA256:
7009fe1faa1697476bdc7027703a2badb84e849b7b0baad5086b087b971f8617
(from the official Boost archive manifest).

libtorrent archive observed SHA256:
f0db58580f4f29ade6cc40fa4ba80e2c9a70c90265cd77332d3cdec37ecf1e6d
(downloaded from the official v2.0.11 release; independently trusted checksum
still needs verification).

Prepare the source build with sh scripts/prepare-torrent-prototype.sh, then
run sh scripts/test-torrent-prototype.sh. These scripts do not install global
dependencies or touch your Myra profile. Build outputs are pinned to the current
Apple Clang 21 toolchain; adapting another toolchain requires resolving its
Boost library output paths rather than silently linking arbitrary archives.

OpenSSL SHA256 a2157c2830efdec3788939b00c9b0638306d3f0bbb76dc4832ee503bb397df98
was verified against the upstream release checksum.
The prototype executable's LC_BUILD_VERSION specifies macOS 14.0 and links
only Apple system frameworks/libraries. Running on an actual macOS 14 host has
not been tested.
