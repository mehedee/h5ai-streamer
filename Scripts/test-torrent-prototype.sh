#!/bin/sh
set -eu
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROTOTYPE_ROOT="$PROJECT_ROOT/.build/torrent-prototype"
LT_ROOT="$PROTOTYPE_ROOT/libtorrent-rasterbar-2.0.11"
BOOST_ROOT="$PROTOTYPE_ROOT/boost_1_85_0"
LT_LIB="$LT_ROOT/bin/darwin-21.0.0/release/cxxstd-17-iso/deprecated-functions-off/link-static/threading-multi/visibility-hidden/libtorrent-rasterbar.a"
BOOST_LIB="$BOOST_ROOT/bin.v2/libs/system/build/darwin-21.0.0/release/cxxstd-17-iso/deprecated-functions-off/link-static/visibility-hidden/libboost_system.a"
SSL_ROOT="$PROTOTYPE_ROOT/openssl-3.6.5"
test -f "$LT_LIB"
test -f "$BOOST_LIB"
clang++ -std=c++17 -mmacosx-version-min=14.0 -O2 \
  -DTORRENT_NO_DEPRECATE -DTORRENT_USE_OPENSSL=1 -DTORRENT_SSL_PEERS \
  -DTORRENT_USE_LIBCRYPTO -DBOOST_ASIO_HAS_STD_CHRONO -DBOOST_ASIO_NO_DEPRECATED \
  -DBOOST_ALL_NO_LIB -DBOOST_SYSTEM_NO_DEPRECATED \
  -I"$LT_ROOT/include" -I"$BOOST_ROOT" -I"$SSL_ROOT/include" \
  "$PROJECT_ROOT/prototypes/torrent-engine/streaming-smoke.cpp" \
  "$LT_ROOT/deps/try_signal/try_signal.cpp" "$LT_ROOT/deps/try_signal/signal_error_code.cpp" \
  "$LT_LIB" "$BOOST_LIB" "$SSL_ROOT/libssl.a" "$SSL_ROOT/libcrypto.a" \
  -framework CoreFoundation -framework SystemConfiguration -framework Security -lpthread \
  -o "$PROTOTYPE_ROOT/streaming-smoke"
FIXTURE_PARENT=$(mktemp -d "$PROTOTYPE_ROOT/fixture.XXXXXX")
"$PROTOTYPE_ROOT/streaming-smoke" "$FIXTURE_PARENT/data"
otool -L "$PROTOTYPE_ROOT/streaming-smoke"
