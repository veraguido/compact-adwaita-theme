#!/usr/bin/env bash
# Refresh vendor/adw-gtk3 from an adw-gtk3 release tarball.
#
#   scripts/update-vendor.sh v6.5
set -euo pipefail

TAG="${1:?usage: $0 <adw-gtk3 release tag, e.g. v6.5>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/vendor/adw-gtk3"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

base="https://github.com/lassekongo83/adw-gtk3"
curl -fsSL -o "$TMP/adw.tar.xz" "$base/releases/download/$TAG/adw-gtk3${TAG}.tar.xz"
curl -fsSL -o "$TMP/LICENSE" "https://raw.githubusercontent.com/lassekongo83/adw-gtk3/$TAG/LICENSE"
tar -xf "$TMP/adw.tar.xz" -C "$TMP"

rm -rf "$VENDOR"
mkdir -p "$VENDOR/gtk-3.0" "$VENDOR/gtk-4.0"
cp "$TMP/adw-gtk3/gtk-3.0/gtk.css" "$VENDOR/gtk-3.0/gtk.css"
cp "$TMP/adw-gtk3-dark/gtk-3.0/gtk.css" "$VENDOR/gtk-3.0/gtk-dark.css"
cp -r "$TMP/adw-gtk3/gtk-3.0/assets" "$VENDOR/gtk-3.0/"
cp "$TMP/adw-gtk3/gtk-3.0/thumbnail.png" "$VENDOR/gtk-3.0/thumbnail.png"
cp "$TMP/adw-gtk3-dark/gtk-3.0/thumbnail.png" "$VENDOR/gtk-3.0/thumbnail-dark.png"
cp "$TMP/adw-gtk3/gtk-4.0/libadwaita.css" "$TMP/adw-gtk3/gtk-4.0/libadwaita-tweaks.css" "$VENDOR/gtk-4.0/"
cp -r "$TMP/adw-gtk3/gtk-4.0/assets" "$VENDOR/gtk-4.0/"
cp "$TMP/LICENSE" "$VENDOR/LICENSE"
echo "$TAG" >"$VENDOR/VERSION"
echo "Vendored adw-gtk3 $TAG"
