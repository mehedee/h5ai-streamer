#!/bin/sh
# Reproducible local feasibility build. Nothing is installed globally or shipped.
set -eu
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TASK_ROOT="$PROJECT_ROOT/.build/torrent-prototype"
mkdir -p "$TASK_ROOT"
cd "$TASK_ROOT"
fetch_checked() {
  name="$1"
  url="$2"
  checksum="$3"
  if ! test -f "$name"; then
    curl --fail --location --silent --show-error --max-time 180 "$url" -o "$name"
  fi
  printf '%s  %s\n' "$checksum" "$name" | shasum -a 256 -c -
}
fetch_checked boost-1.85.0.tar.bz2 \
  https://archives.boost.io/release/1.85.0/source/boost_1_85_0.tar.bz2 \
  7009fe1faa1697476bdc7027703a2badb84e849b7b0baad5086b087b971f8617
fetch_checked libtorrent-2.0.11.tar.gz \
  https://github.com/arvidn/libtorrent/releases/download/v2.0.11/libtorrent-rasterbar-2.0.11.tar.gz \
  f0db58580f4f29ade6cc40fa4ba80e2c9a70c90265cd77332d3cdec37ecf1e6d
fetch_checked openssl-3.6.5.tar.gz \
  https://github.com/openssl/openssl/releases/download/openssl-3.6.5/openssl-3.6.5.tar.gz \
  a2157c2830efdec3788939b00c9b0638306d3f0bbb76dc4832ee503bb397df98
test -d boost_1_85_0 || tar -xjf boost-1.85.0.tar.bz2
test -d libtorrent-rasterbar-2.0.11 || tar -xzf libtorrent-2.0.11.tar.gz
test -d openssl-3.6.5 || tar -xzf openssl-3.6.5.tar.gz
if ! test -x boost_1_85_0/b2; then
  (cd boost_1_85_0 && ./bootstrap.sh --with-toolset=clang --with-libraries=system > bootstrap.log 2>&1)
fi
(cd openssl-3.6.5 &&
  CFLAGS=-mmacosx-version-min=14.0 ./Configure darwin64-arm64-cc no-shared no-tests \
    --prefix="$TASK_ROOT/openssl-install" > ../openssl-build.log 2>&1 &&
  make -j4 build_libs >> ../openssl-build.log 2>&1)
(cd libtorrent-rasterbar-2.0.11 &&
  BOOST_ROOT="$TASK_ROOT/boost_1_85_0" ../boost_1_85_0/b2 -j4 \
    toolset=darwin cxxstd=17 variant=release link=static boost-link=static \
    crypto=openssl openssl-include="$TASK_ROOT/openssl-3.6.5/include" \
    openssl-lib="$TASK_ROOT/openssl-3.6.5" \
    cxxflags=-mmacosx-version-min=14.0 linkflags=-mmacosx-version-min=14.0 \
    deprecated-functions=off warnings=off > ../engine-build.log 2>&1)
printf 'Native prototype sources built. Run sh scripts/test-torrent-prototype.sh from the project.\n'
