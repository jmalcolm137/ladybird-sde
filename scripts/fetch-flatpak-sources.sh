#!/usr/bin/env bash
# Populate the source trees that Meta/CMake/flatpak/io.github.jmalcolm137.LadybirdSDE.json
# packages. Flatpak manifests cannot fetch a git checkout at an arbitrary commit
# with the sparse, blobless layout the LibGUI port needs, so stage it here.
#
#   scripts/fetch-flatpak-sources.sh
#   flatpak-builder --force-clean build/flatpak-build \
#       Meta/CMake/flatpak/io.github.jmalcolm137.LadybirdSDE.json
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="${FLATPAK_SOURCES:-$ROOT/Meta/CMake/flatpak/sources}"
LIBGUI_REPO="${LIBGUI_REPO:-https://github.com/jmalcolm137/libgui-wayland.git}"
LIBGUI_COMMIT="${LIBGUI_COMMIT:-c5bef619bc27b650742f4d1f087f6f39ecb00160}"

LIBGUI_DIR="$SOURCES/libgui-wayland"
SERENITY_DIR="$LIBGUI_DIR/serenity"

mkdir -p "$SOURCES"

if [[ ! -d "$LIBGUI_DIR/.git" ]]; then
    echo "==> cloning libgui-wayland"
    git clone "$LIBGUI_REPO" "$LIBGUI_DIR"
fi

echo "==> checking out libgui-wayland $LIBGUI_COMMIT"
git -C "$LIBGUI_DIR" fetch --depth 1 origin "$LIBGUI_COMMIT"
git -C "$LIBGUI_DIR" checkout --quiet --detach "$LIBGUI_COMMIT"
# Drop stale build output but keep the Serenity checkout this script manages.
git -C "$LIBGUI_DIR" clean -qffdx -e serenity

echo "==> fetching the pinned SerenityOS source"
SERENITY_SRC="$SERENITY_DIR" "$LIBGUI_DIR/scripts/fetch-serenity.sh"

echo "==> sources ready in $SOURCES"
