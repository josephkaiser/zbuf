#!/bin/sh
# macOS part of zbuf's install, run by ../install.sh. Builds zbuf.app:
#
#   zbuf.app                          windowless launcher that Finder can open
#                                     PDF/EPUB with; hands files to zbuf
#   zbuf.app/Contents/Helpers/zathura.app
#                                     a copy of zathura (from Homebrew) in a bundle
#                                     of its own, so its window shows up in
#                                     Cmd-Tab and the Dock as "zathura + zbuf"
#                                     with zbuf's icon; zbuf runs this one
#
#   ./install.sh install|uninstall
#
# The copy is refreshed on every install, so rerun after upgrading zathura.
# APPDIR (default ~/Applications) is where zbuf.app goes. Making zbuf.app the
# default viewer is up to ../install.sh, which asks first.

set -eu

HERE=$(dirname "$(realpath "$0")")
ZBUF=$(dirname "$HERE")
APP=${APPDIR:-$HOME/Applications}/zbuf.app
HELPER=$APP/Contents/Helpers/zathura.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

plist() { # id name executable [extra keys]
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$1</string>
  <key>CFBundleName</key><string>$2</string>
  <key>CFBundleExecutable</key><string>$3</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
${4-}
</dict>
</plist>
PLIST
}

install() {
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$HELPER/Contents/MacOS" "$HELPER/Contents/Resources"

  swiftc -O "$HERE/zbuf-app.swift" -o "$APP/Contents/MacOS/zbuf-app"
  cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/"
  ln -s "$ZBUF/zbuf" "$APP/Contents/Resources/zbuf"
  plist local.zbuf zbuf zbuf-app '  <key>LSUIElement</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>com.adobe.pdf</string><string>org.idpf.epub-container</string></array>
    </dict>
  </array>' >"$APP/Contents/Info.plist"

  # a copy, not a link: macOS picks the bundle from where the binary really is
  zathura=$(command -v zathura) || { echo "zbuf: zathura is not on PATH" >&2; exit 1; }
  cp "$(realpath "$zathura")" "$HELPER/Contents/MacOS/zathura"
  cp "$HERE/AppIcon.icns" "$HELPER/Contents/Resources/"
  plist local.zbuf.zathura "zathura + zbuf" zathura >"$HELPER/Contents/Info.plist"
  codesign --force --sign - "$HELPER" "$APP" 2>/dev/null

  # zbuf runs the zathura it finds next to itself
  ln -sf "$HELPER/Contents/MacOS/zathura" "$ZBUF/zathura"

  "$LSREGISTER" -f "$APP"
  echo "zbuf.app installed in $(dirname "$APP")"
}

uninstall() {
  if [ -d "$APP" ]; then
    "$LSREGISTER" -u "$APP"
    rm -rf "$APP"
  fi
  rm -f "$ZBUF/zathura"
}

case ${1-} in
install | uninstall) "$1" ;;
*)
  sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"
  exit 1
  ;;
esac
