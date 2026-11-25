#!/usr/bin/env bash
# Package an existing build tree as a self-contained Flatpak bundle.
#
#   scripts/make-flatpak.sh [version]
#
# The bundle is written to build/flatpak/LadybirdSDE-<version>-<arch>.flatpak.
# It uses org.freedesktop.Platform/Sdk 26.08 and a private app id,
# io.github.jmalcolm137.LadybirdSDE, so it can be installed alongside the
# upstream org.ladybird.Ladybird Flatpak.
#
# Requirements:
#   * Build/release/libexec/LadybirdEngine (scripts/build-engine.sh)
#   * build/chrome/Ladybird (scripts/build-chrome.sh)
#   * a LibGUI-for-Wayland Lagom build in ../libgui-wayland/build/lagom
#   * flatpak, patchelf, objdump, and the Freedesktop SDK 26.08:
#       flatpak install --user flathub org.freedesktop.Sdk//26.08 \
#                                      org.freedesktop.Platform//26.08
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LADYBIRD_BUILD="${LADYBIRD_BUILD:-$ROOT/Build/release}"
LIBGUI_WAYLAND_ROOT="${LIBGUI_WAYLAND_ROOT:-$ROOT/../libgui-wayland}"
SERENITY="${SERENITY:-$LIBGUI_WAYLAND_ROOT/serenity}"
LAGOM="${LAGOM:-$LIBGUI_WAYLAND_ROOT/build/lagom}"

APP_ID="io.github.jmalcolm137.LadybirdSDE"
APP_NAME="LadybirdSDE"
RUNTIME_VERSION="26.08"
ARCH="${ARCH:-$(uname -m)}"
VERSION="${1:-$(date +%Y.%m.%d)}"

WORK="${WORK:-$ROOT/build/flatpak}"
BUILD="$WORK/build"
REPO="$WORK/repo"
BUNDLE="$WORK/$APP_NAME-$VERSION-$ARCH.flatpak"

die() { echo "make-flatpak: $*" >&2; exit 1; }

[[ -x "$LADYBIRD_BUILD/libexec/LadybirdEngine" ]] || die "build the engine host first (scripts/build-engine.sh)"
[[ -x "$ROOT/build/chrome/Ladybird" ]] || die "build the frontend first (scripts/build-chrome.sh)"
[[ -d "$LAGOM/lib" ]] || die "missing LibGUI Lagom build at $LAGOM"
command -v flatpak >/dev/null || die "flatpak is not installed"
command -v patchelf >/dev/null || die "patchelf is not installed"

rm -rf "$WORK"
mkdir -p "$WORK"

echo "==> creating $APP_ID sandbox"
flatpak build-init "$BUILD" "$APP_ID" "org.freedesktop.Sdk//$RUNTIME_VERSION" "org.freedesktop.Platform//$RUNTIME_VERSION"

F="$BUILD/files"
mkdir -p "$F/bin" "$F/libexec" "$F/lib/ladybird" "$F/share/applications" \
         "$F/share/icons/hicolor/32x32/apps" "$F/share/metainfo"

echo "==> frontend"
# The executable basename is the Wayland app_id LibWM reports, so keep it as
# LadybirdSDE and let the Flatpak metadata supply the environment.
cp -a "$ROOT/build/chrome/Ladybird" "$F/bin/$APP_NAME"

echo "==> engine host and helpers"
cp -a "$LADYBIRD_BUILD/libexec/." "$F/libexec/"

echo "==> Ladybird libraries"
cp -a "$LADYBIRD_BUILD/lib/." "$F/lib/ladybird/"
if [[ -d "$LADYBIRD_BUILD/vcpkg_installed/x64-linux-dynamic/lib" ]]; then
    cp -a "$LADYBIRD_BUILD/vcpkg_installed/x64-linux-dynamic/lib/." "$F/lib/ladybird/"
fi

echo "==> LibGUI libraries"
# Copy the transitive closure the frontend resolves against the Lagom build,
# rather than the whole (much larger) library directory.
for name in $(LD_LIBRARY_PATH="$LAGOM/lib" ldd "$ROOT/build/chrome/Ladybird" | grep "$LAGOM/lib/" | awk '{print $1}' | sort -u); do
    for file in "$LAGOM/lib/$name" "$LAGOM/lib/$name".*; do
        [[ -e "$file" ]] || continue
        cp -a "$file" "$F/lib/"
    done
done

echo "==> resources"
cp -a "$LADYBIRD_BUILD/share/Lagom/." "$F/share/Lagom/"
cp -a "$SERENITY/Base/res/." "$F/share/res/"

echo "==> desktop entry and metadata"
cat > "$F/share/applications/$APP_ID.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Ladybird SDE
GenericName=Web Browser
Comment=LibGUI frontend for the Ladybird web browser
Exec=$APP_NAME %U
TryExec=$APP_NAME
Icon=$APP_ID
Terminal=false
Categories=Network;WebBrowser;
MimeType=text/html;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/about;
StartupNotify=true
StartupWMClass=$APP_NAME
X-Flatpak=$APP_ID
EOF

cat > "$F/share/metainfo/$APP_ID.metainfo.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>$APP_ID</id>
  <name>Ladybird SDE</name>
  <summary>LibGUI frontend for the Ladybird web browser</summary>
  <description>
    <p>Ladybird SDE is a Serenity Desktop Environment frontend for the Ladybird
    web browser. The web engine is an unmodified Ladybird build; only the
    browser chrome is replaced with the LibGUI-for-Wayland stack.</p>
  </description>
  <launchable type="desktop-id">$APP_ID.desktop</launchable>
  <url type="homepage">https://github.com/jmalcolm137/ladybird-sde</url>
  <developer id="io.github.jmalcolm137">
    <name>jmalcolm137</name>
  </developer>
  <metadata_license>0BSD</metadata_license>
  <project_license>BSD-2-Clause</project_license>
  <content_rating type="oars-1.1"/>
  <releases>
    <release version="$VERSION" date="$(date +%Y-%m-%d)"/>
  </releases>
</component>
EOF

if [[ -f "$SERENITY/Base/res/icons/32x32/app-browser.png" ]]; then
    install -m 0644 "$SERENITY/Base/res/icons/32x32/app-browser.png" "$F/share/icons/hicolor/32x32/apps/$APP_ID.png"
fi

echo "==> fixing RPATHs"
patch_elf() {
    [[ -f "$1" && ! -L "$1" ]] || return 0
    file -b "$1" | grep -q ELF || return 0
    patchelf --force-rpath --set-rpath "$2" "$1"
}
patch_elf "$F/bin/$APP_NAME" '$ORIGIN/../lib'
for file in "$F"/libexec/*; do patch_elf "$file" '$ORIGIN/../lib/ladybird'; done
for file in "$F"/lib/ladybird/*; do patch_elf "$file" '$ORIGIN'; done
for file in "$F"/lib/liblagom*.so* "$F"/lib/libwm.so*; do patch_elf "$file" '$ORIGIN'; done

echo "==> finishing sandbox"
flatpak build-finish "$BUILD" \
    --command="$APP_NAME" \
    --share=ipc --share=network \
    --socket=wayland --socket=fallback-x11 --socket=pulseaudio --socket=session-bus \
    --device=dri --device=input \
    --filesystem=xdg-download \
    --filesystem=xdg-config/gtk-3.0:ro \
    --talk-name=org.freedesktop.portal.Desktop \
    --talk-name=org.freedesktop.Notifications \
    --env=LADYBIRD_ENGINE_HOST=/app/libexec/LadybirdEngine \
    --env=LADYBIRD_SOURCE_DIR=/app \
    --env=SERENITY_RES_ROOT=/app/share/res

echo "==> exporting bundle"
flatpak build-export "$REPO" "$BUILD" stable
flatpak build-bundle --runtime-repo=https://flathub.org/repo/flathub.flatpakrepo \
    "$REPO" "$BUNDLE" "$APP_ID" stable

echo "==> $BUNDLE"
ls -lh "$BUNDLE"
