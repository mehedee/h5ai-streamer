#!/bin/sh
set -eu
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TASK_ROOT="$PROJECT_ROOT/.build/torrent-prototype"
LT_ROOT="$TASK_ROOT/libtorrent-rasterbar-2.0.11"
BOOST_ROOT="$TASK_ROOT/boost_1_85_0"
SSL_ROOT="$TASK_ROOT/openssl-3.6.5"
LT_LIB="$LT_ROOT/bin/darwin-21.0.0/release/cxxstd-17-iso/deprecated-functions-off/link-static/threading-multi/visibility-hidden/libtorrent-rasterbar.a"
BOOST_LIB="$BOOST_ROOT/bin.v2/libs/system/build/darwin-21.0.0/release/cxxstd-17-iso/deprecated-functions-off/link-static/visibility-hidden/libboost_system.a"
test -f "$LT_LIB" || sh "$PROJECT_ROOT/Scripts/prepare-torrent-prototype.sh"
mkdir -p "$PROJECT_ROOT/.build/torrent-engine"
clang++ -std=c++17 -mmacosx-version-min=14.0 -O2 \
  -DTORRENT_NO_DEPRECATE -DTORRENT_USE_OPENSSL=1 -DTORRENT_SSL_PEERS \
  -DTORRENT_USE_LIBCRYPTO -DBOOST_ASIO_HAS_STD_CHRONO -DBOOST_ASIO_NO_DEPRECATED \
  -DBOOST_ALL_NO_LIB -DBOOST_SYSTEM_NO_DEPRECATED \
  -I"$LT_ROOT/include" -I"$BOOST_ROOT" -I"$SSL_ROOT/include" \
  "$PROJECT_ROOT/Native/TorrentEngine/main.cpp" \
  "$LT_ROOT/deps/try_signal/try_signal.cpp" "$LT_ROOT/deps/try_signal/signal_error_code.cpp" \
  "$LT_LIB" "$BOOST_LIB" "$SSL_ROOT/libssl.a" "$SSL_ROOT/libcrypto.a" \
  -framework CoreFoundation -framework SystemConfiguration -framework Security -lpthread \
  -o "$PROJECT_ROOT/.build/torrent-engine/myra-torrent-engine"
