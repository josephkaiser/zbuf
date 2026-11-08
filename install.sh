#!/bin/sh
# Install zbuf: build the zbuf-index library that zbuf loads into its zathura,
# link zbuf onto PATH, and add a launcher so file managers can open documents
# in zbuf (zbuf.app on macOS, a .desktop entry elsewhere). Zathura itself and
# its plugins are not touched.
#
#   ./install.sh             install (safe to rerun, e.g. after a zathura upgrade)
#   ./install.sh uninstall   undo all of that
#   ./install.sh default     make zbuf the default PDF/EPUB viewer (asks first)
#   ./install.sh build       only build the library (zbuf runs this itself)
#
# install asks before making zbuf the default viewer, and only when run in a
# terminal. ZBUF_DEFAULT=yes or no answers for it. uninstall puts back the
# viewer you had before. BINDIR (default ~/.local/bin) is where zbuf is linked.
#
# Needs zathura with a PDF plugin (mupdf or poppler) and its development
# headers, pkg-config, a C compiler, and dbus-daemon and dbus-send.

set -eu

HERE=$(dirname "$(realpath "$0")")
BINDIR=${BINDIR:-$HOME/.local/bin}
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/zbuf
# what the default viewer was before zbuf, one "type handler" per line
PREVIOUS=$STATE/previous-viewers

case $(uname) in
Darwin)
  OS=macos
  PLUGIN=$HERE/zbuf-index.dylib
  APP=${APPDIR:-$HOME/Applications}/zbuf.app
  APPID=local.zbuf
  TYPES="com.adobe.pdf org.idpf.epub-container"
  ;;
*)
  OS=xdg
  PLUGIN=$HERE/zbuf-index.so
  APPS=${XDG_DATA_HOME:-$HOME/.local/share}/applications
  DESKTOP=zbuf.desktop
  TYPES="application/pdf application/epub+zip"
  ;;
esac

die() { echo "zbuf install: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "$1 not found; $2"; }

check() {
  need zathura "install zathura first"
  need cc "install a C compiler (Xcode command line tools on macOS, gcc or clang elsewhere)"
  need pkg-config "install pkg-config (or pkgconf)"
  need dbus-daemon "install dbus"
  need dbus-send "install dbus"
  pkg-config --exists zathura gtk+-3.0 gmodule-2.0 ||
    die "zathura's headers not found by pkg-config; install the -dev/-devel packages for zathura, girara and gtk3"
  command -v sqlite3 >/dev/null ||
    echo "zbuf install: sqlite3 not found; zbuf with no files won't reopen your last document" >&2
  if ! zathura --version 2>&1 | grep -q '(plugin) pdf-'; then
    echo "zbuf install: zathura has no PDF plugin; install zathura-pdf-mupdf or zathura-pdf-poppler" >&2
    old_mupdf_hint
  fi
}

build() {
  src=$HERE/zbuf-index.c
  # shellcheck disable=SC2046
  case $OS in
  macos)
    # zathura's own functions are found in zathura when it loads us
    cc -dynamiclib -undefined dynamic_lookup -O2 -Wall \
      $(pkg-config --cflags zathura gtk+-3.0 gmodule-2.0) -o "$PLUGIN.new" "$src" \
      $(pkg-config --libs gtk+-3.0 gmodule-2.0)
    ;;
  xdg)
    cc -shared -fPIC -O2 -Wall \
      $(pkg-config --cflags zathura gtk+-3.0 gmodule-2.0) -o "$PLUGIN.new" "$src" \
      $(pkg-config --libs gtk+-3.0 gmodule-2.0) -ldl
    ;;
  esac
  # a new file rather than rewriting the old one, which a running zathura has loaded
  mv -f "$PLUGIN.new" "$PLUGIN"
}

# earlier versions of zbuf replaced Homebrew's mupdf plugin with their own;
# put mupdf back
undo_old_layout() {
  command -v brew >/dev/null || return 0
  plugins=$(brew --prefix zathura 2>/dev/null)/lib/zathura
  mupdf=$(brew --prefix zathura-pdf-mupdf 2>/dev/null)/libpdf-mupdf.dylib
  [ -L "$plugins/zbuf-index.dylib" ] || return 0
  rm -f "$plugins/zbuf-index.dylib"
  [ -f "$mupdf" ] && ln -sf "$mupdf" "$plugins/libpdf-mupdf.dylib"
  echo "zbuf install: removed the old zbuf plugin from $plugins and restored mupdf"
}

old_mupdf_hint() {
  command -v brew >/dev/null || return 0
  mupdf=$(brew --prefix zathura-pdf-mupdf 2>/dev/null)/libpdf-mupdf.dylib
  [ -f "$mupdf" ] || return 0
  echo "  Homebrew's mupdf plugin has to be linked into zathura's plugin dir:" >&2
  echo "  ln -s $mupdf $(brew --prefix zathura)/lib/zathura/" >&2
}

# ---- launcher ----

launcher_install() {
  case $OS in
  macos) "$HERE/macos/install.sh" install ;;
  xdg)
    mkdir -p "$APPS"
    cat >"$APPS/$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=zbuf
GenericName=Document Viewer
Comment=Open documents as buffers in one zathura window
Exec="$HERE/zbuf" %F
Icon=org.pwmt.zathura
Terminal=false
Categories=Office;Viewer;
MimeType=$(printf '%s;' $TYPES)
EOF
    command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" 2>/dev/null || true
    echo "zbuf installed in your applications menu ($APPS/$DESKTOP)"
    ;;
  esac
}

launcher_uninstall() {
  case $OS in
  macos) "$HERE/macos/install.sh" uninstall ;;
  xdg)
    rm -f "$APPS/$DESKTOP"
    command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" 2>/dev/null || true
    ;;
  esac
}

# ---- default viewer ----

ours() { [ $OS = macos ] && echo $APPID || echo $DESKTOP; }

get_default() {
  case $OS in
  macos) "$APP/Contents/MacOS/zbuf-app" --get-default "$1" ;;
  xdg) xdg-mime query default "$1" 2>/dev/null || true ;;
  esac
}

set_default() {
  case $OS in
  macos) "$APP/Contents/MacOS/zbuf-app" --set-default "$1" "$2" ;;
  xdg) xdg-mime default "$2" "$1" ;;
  esac
}

ask_default() {
  [ $OS = xdg ] && ! command -v xdg-mime >/dev/null && {
    echo "zbuf install: xdg-mime not found; set zbuf as the PDF viewer in your desktop's settings if you want it" >&2
    return 0
  }
  answer=${ZBUF_DEFAULT-}
  if [ -z "$answer" ]; then
    if ! [ -t 0 ]; then
      echo "To open PDF and EPUB files in zbuf by default: $0 default"
      return 0
    fi
    printf 'Open PDF and EPUB files in zbuf by default? Your current viewer is put back on uninstall. [y/N] '
    read -r answer || answer=
  fi
  case $answer in
  [yY]*) make_default ;;
  *) echo "Left your default viewer alone. To change that later: $0 default" ;;
  esac
}

make_default() {
  mkdir -p "$STATE"
  for type in $TYPES; do
    was=$(get_default "$type")
    [ "$was" = "$(ours)" ] && continue
    # remember the first viewer we replaced, not ourselves on a rerun
    grep -q "^$type " "$PREVIOUS" 2>/dev/null || printf '%s %s\n' "$type" "$was" >>"$PREVIOUS"
    set_default "$type" "$(ours)"
  done
  echo "zbuf is now the default viewer for PDF and EPUB"
}

restore_default() {
  [ -f "$PREVIOUS" ] || return 0
  while read -r type was; do
    # only if zbuf is still the default; leave a viewer you picked since alone
    [ "$(get_default "$type")" = "$(ours)" ] || continue
    if [ -n "$was" ]; then
      set_default "$type" "$was"
    elif [ $OS = xdg ]; then
      # there was none before; drop zbuf's line so the desktop picks again
      list=${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list
      [ -f "$list" ] && sed -i.bak "\\|^$type=$DESKTOP;*\$|d" "$list" && rm -f "$list.bak"
    fi
  done <"$PREVIOUS"
  rm -f "$PREVIOUS"
  rmdir "$STATE" 2>/dev/null || true
  echo "restored your previous PDF/EPUB viewer"
}

# ---- commands ----

case ${1-install} in
build)
  build
  ;;
install)
  check
  undo_old_layout
  build
  mkdir -p "$BINDIR"
  ln -sf "$HERE/zbuf" "$BINDIR/zbuf"
  launcher_install
  ask_default
  echo "zbuf installed: $BINDIR/zbuf"
  case :$PATH: in *:"$BINDIR":*) ;; *) echo "note: $BINDIR is not on your PATH" ;; esac
  ;;
default)
  [ $OS = xdg ] || [ -d "$APP" ] || die "run $0 first"
  ask_default
  ;;
uninstall)
  restore_default
  launcher_uninstall
  undo_old_layout
  # only our link, not some other zbuf
  [ "$(readlink "$BINDIR/zbuf" 2>/dev/null)" = "$HERE/zbuf" ] && rm -f "$BINDIR/zbuf"
  rm -f "$HERE/zbuf-index.dylib" "$HERE/zbuf-index.so"
  echo "zbuf removed"
  ;;
*)
  sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"
  exit 1
  ;;
esac
