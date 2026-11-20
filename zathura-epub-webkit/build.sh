#!/bin/sh
# Build the WebKit EPUB plugin for zathura into ./plugin/: the plugin library
# and the helper it starts. zbuf adds ./plugin to zathura's plugin path, and
# zbuf-index hands EPUBs to this plugin instead of MuPDF.
#
#   ./build.sh          build (only what changed)
#   ./build.sh clean    remove the build and the cached book layouts
set -eu

HERE=$(dirname "$(realpath "$0")")
OUT=$HERE/plugin

case ${1-build} in
clean)
  rm -rf "$OUT" "$HOME/Library/Caches/zathura-epub-webkit"
  exit 0
  ;;
esac

mkdir -p "$OUT"

# new files rather than rewriting old ones, which a running zathura may have loaded
if [ ! -f "$OUT/epub-webkit-helper" ] || [ "$HERE/helper.swift" -nt "$OUT/epub-webkit-helper" ]; then
  swiftc -O -swift-version 5 "$HERE/helper.swift" -o "$OUT/epub-webkit-helper.new"
  mv -f "$OUT/epub-webkit-helper.new" "$OUT/epub-webkit-helper"
fi

if [ ! -f "$OUT/libepub-webkit.dylib" ] || [ "$HERE/plugin.c" -nt "$OUT/libepub-webkit.dylib" ]; then
  # zathura's own functions are found in zathura when it loads us
  # shellcheck disable=SC2046
  cc -dynamiclib -undefined dynamic_lookup -O2 -Wall \
    $(pkg-config --cflags zathura cairo glib-2.0) -o "$OUT/libepub-webkit.dylib.new" "$HERE/plugin.c" \
    $(pkg-config --libs cairo glib-2.0)
  mv -f "$OUT/libepub-webkit.dylib.new" "$OUT/libepub-webkit.dylib"
fi
