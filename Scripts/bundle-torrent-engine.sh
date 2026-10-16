#!/bin/sh
set -eu
sh "$SRCROOT/Scripts/build-torrent-engine.sh"
APP_CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
mkdir -p "$APP_CONTENTS/Helpers" "$APP_CONTENTS/Resources/Licenses"
cp "$SRCROOT/.build/torrent-engine/myra-torrent-engine" "$APP_CONTENTS/Helpers/myra-torrent-engine"
chmod 755 "$APP_CONTENTS/Helpers/myra-torrent-engine"
TASK_ROOT="$SRCROOT/.build/torrent-prototype"
cp "$TASK_ROOT/libtorrent-rasterbar-2.0.11/LICENSE" "$APP_CONTENTS/Resources/Licenses/libtorrent-BSD.txt"
cp "$TASK_ROOT/boost_1_85_0/LICENSE_1_0.txt" "$APP_CONTENTS/Resources/Licenses/Boost.txt"
cp "$TASK_ROOT/openssl-3.6.5/LICENSE.txt" "$APP_CONTENTS/Resources/Licenses/OpenSSL-Apache-2.0.txt"
codesign --force --sign - "$APP_CONTENTS/Helpers/myra-torrent-engine"
