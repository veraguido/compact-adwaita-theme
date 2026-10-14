#!/usr/bin/env bash
# Build the ggtk themes into ./build
#
#   ./build.sh [--density dense|compact|mild] [--libadwaita-css FILE]
#
# Output:
#   build/themes/ggtk        light theme (GTK3 + non-libadwaita GTK4)
#   build/themes/ggtk-dark   dark theme  (GTK3 + non-libadwaita GTK4)
#   build/libadwaita/ggtk.css  override for libadwaita apps
#                              (imported from ~/.config/gtk-4.0/gtk.css)
#
# Both theme directories also get a gnome-shell/ stylesheet (for the User
# Themes extension), generated from the installed GNOME Shell.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR="$ROOT/vendor/adw-gtk3"
SRC="$ROOT/src"
OUT="$ROOT/build"
NAME="ggtk"

DENSITY="${GGTK_DENSITY:-dense}"
LIBADWAITA_CSS="${GGTK_LIBADWAITA_CSS:-}"

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --density) DENSITY="$2"; shift 2 ;;
        --libadwaita-css) LIBADWAITA_CSS="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "build.sh: unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

case "$DENSITY" in
    dense)   SCALE=(--pad-scale 0.5  --size-scale 0.55 --radius-scale 0.5) ;;
    compact) SCALE=(--pad-scale 0.7  --size-scale 0.7  --radius-scale 0.7) ;;
    mild)    SCALE=(--pad-scale 0.85 --size-scale 0.85 --radius-scale 0.85) ;;
    *) echo "build.sh: unknown density '$DENSITY' (dense|compact|mild)" >&2; exit 1 ;;
esac

command -v python3 >/dev/null || { echo "build.sh: python3 is required" >&2; exit 1; }
compact() { python3 -I "$ROOT/scripts/compact.py" "${SCALE[@]}" "$@"; }

# libadwaita apps use the stylesheet compiled into libadwaita itself, so prefer
# the installed one; fall back to the copy shipped with adw-gtk3.
find_libadwaita_css() {
    local lib dest="$1"
    if command -v gresource >/dev/null; then
        for lib in /usr/lib64/libadwaita-1.so.0 /usr/lib/libadwaita-1.so.0 \
                   /usr/lib/*-linux-gnu/libadwaita-1.so.0; do
            [[ -e "$lib" ]] || continue
            if gresource extract "$lib" /org/gnome/Adwaita/styles/gtk.css >"$dest" 2>/dev/null \
                && [[ -s "$dest" ]]; then
                echo "$lib"
                return
            fi
        done
    fi
    cp "$VENDOR/gtk-4.0/libadwaita.css" "$dest"
    echo "vendor/adw-gtk3 $(cat "$VENDOR/VERSION")"
}

rm -rf "$OUT"
mkdir -p "$OUT/themes" "$OUT/libadwaita" "$OUT/tmp"

# --- GTK3 + GTK4 theme directories ------------------------------------------

# The dense preset has a few hand-tuned exceptions appended after the
# generated rules.
tweaks() {
    if [[ "$DENSITY" == dense ]]; then cat "$SRC/$1/tweaks-dense.css"; fi
}

compact "$VENDOR/gtk-3.0/gtk.css" -o "$OUT/tmp/gtk3-compact.css"
compact "$VENDOR/gtk-3.0/gtk-dark.css" -o "$OUT/tmp/gtk3-compact-dark.css"
compact "$VENDOR/gtk-4.0/libadwaita.css" "$VENDOR/gtk-4.0/libadwaita-tweaks.css" \
    -o "$OUT/tmp/gtk4-compact.css"
tweaks gtk-3.0 | tee -a "$OUT/tmp/gtk3-compact.css" >>"$OUT/tmp/gtk3-compact-dark.css"
tweaks gtk-4.0 >>"$OUT/tmp/gtk4-compact.css"

# Dark palette for GTK4: libadwaita's own dark color definitions, then ggtk's
# darker surfaces. The full set matters for plain GTK4 apps (e.g. pavucontrol):
# GTK evaluates dark mode for ~/.config/gtk-4.0/gtk.css from the system color
# scheme, but for the theme stylesheet only when an app asks for a dark theme.
# Without the full set they'd get dark backgrounds with light-mode text.
dark_palette() {
    python3 -I "$ROOT/scripts/compact.py" --dark-defs "$1"
    cat "$SRC/gtk-4.0/colors-dark.css"
}
dark_palette "$VENDOR/gtk-4.0/libadwaita.css" >"$OUT/tmp/gtk4-colors-dark.css"

make_theme() {
    local theme="$1" variant="$2" dir="$OUT/themes/$1"
    mkdir -p "$dir/gtk-3.0" "$dir/gtk-4.0"

    cat >"$dir/index.theme" <<EOF
[X-GNOME-Metatheme]
Name=$theme
Type=X-GNOME-Metatheme
Comment=Compact Adwaita-style theme based on adw-gtk3
Encoding=UTF-8
GtkTheme=$theme
EOF

    # GTK3: upstream adw-gtk3 + compact layer (+ darker palette)
    local g3="$dir/gtk-3.0"
    cp -r "$VENDOR/gtk-3.0/assets" "$g3/"
    cp "$VENDOR/gtk-3.0/gtk.css" "$g3/adw-gtk3.css"
    cp "$VENDOR/gtk-3.0/gtk-dark.css" "$g3/adw-gtk3-dark.css"
    cp "$OUT/tmp/gtk3-compact.css" "$g3/compact.css"
    cp "$OUT/tmp/gtk3-compact-dark.css" "$g3/compact-dark.css"
    cp "$SRC/gtk-3.0/colors-dark.css" "$g3/colors-dark.css"
    printf '@import url("adw-gtk3-dark.css");\n@import url("compact-dark.css");\n@import url("colors-dark.css");\n' \
        >"$g3/gtk-dark.css"
    if [[ "$variant" == dark ]]; then
        cp "$g3/gtk-dark.css" "$g3/gtk.css"
        cp "$VENDOR/gtk-3.0/thumbnail-dark.png" "$g3/thumbnail.png"
    else
        printf '@import url("adw-gtk3.css");\n@import url("compact.css");\n' >"$g3/gtk.css"
        cp "$VENDOR/gtk-3.0/thumbnail.png" "$g3/thumbnail.png"
    fi

    # GTK4 (non-libadwaita apps): dark/light follows the system color scheme
    local g4="$dir/gtk-4.0"
    cp -r "$VENDOR/gtk-4.0/assets" "$g4/"
    cp "$VENDOR/gtk-4.0/libadwaita.css" "$VENDOR/gtk-4.0/libadwaita-tweaks.css" "$g4/"
    cp "$OUT/tmp/gtk4-compact.css" "$g4/compact.css"
    cp "$OUT/tmp/gtk4-colors-dark.css" "$g4/colors-dark.css"
    printf '@import url("libadwaita.css");\n@import url("libadwaita-tweaks.css");\n@import url("compact.css");\n@import url("colors-dark.css");\n' \
        >"$g4/gtk.css"
    cp "$g4/gtk.css" "$g4/gtk-dark.css"
}

make_theme "$NAME" light
make_theme "$NAME-dark" dark

# --- libadwaita override ----------------------------------------------------

source_desc="$(find_libadwaita_css "$OUT/tmp/libadwaita.css")"
compact "$OUT/tmp/libadwaita.css" -o "$OUT/tmp/libadwaita-compact.css"
app_sheets=""
if command -v gresource >/dev/null; then
    app_sheets="$(python3 -I "$ROOT/scripts/app-css.py" "$OUT/tmp/app-css")"
    [[ "$app_sheets" == 0 ]] && app_sheets=""
fi
tweaks gtk-4.0 >>"$OUT/tmp/libadwaita-compact.css"
{
    echo "/* ggtk override for libadwaita apps (density: $DENSITY)"
    echo " * generated from: $source_desc */"
    cat "$OUT/tmp/libadwaita-compact.css"
    # Installed apps' own stylesheets, mirrored with a specificity boost so
    # they keep beating the generic rules above (see scripts/app-css.py).
    if [[ -n "$app_sheets" ]]; then
        echo "/* app stylesheets ($app_sheets found) */"
        compact --app "$OUT/tmp/libadwaita.css" "$OUT/tmp/app-css"/*
    fi
    dark_palette "$OUT/tmp/libadwaita.css"
} >"$OUT/libadwaita/$NAME.css"

# --- GNOME Shell --------------------------------------------------------------

# GNOME Shell always loads its stock stylesheet (which follows the light/dark
# setting) and puts the User Themes stylesheet on top of it. So:
#   ggtk       only overrides sizes (mirroring the stock selectors, like the
#              libadwaita override), and keeps following light/dark;
#   ggtk-dark  is a complete, always-dark stylesheet with the darker palette.
# Both are generated from the installed shell to match its version exactly.
SHELL_RES=/usr/share/gnome-shell/gnome-shell-theme.gresource
shell_desc="skipped (GNOME Shell or gresource not found)"
if command -v gresource >/dev/null && [[ -e "$SHELL_RES" ]] \
    && gresource extract "$SHELL_RES" /org/gnome/shell/theme/gnome-shell-dark.css >"$OUT/tmp/shell-dark.css" \
    && gresource extract "$SHELL_RES" /org/gnome/shell/theme/gnome-shell-light.css >"$OUT/tmp/shell-light.css"; then
    shell_version="$(gnome-shell --version 2>/dev/null || echo 'GNOME Shell')"
    shell_desc="$shell_version"
    # Things whose size is geometry, not padding.
    shell_exclude=(--exclude '(?<![\w-])switch(?![\w-])|toggle-switch|ripple|workspace-thumbnail|window-clone|pie-timer'
                   --exclude 'keyboard|\.key\b|osk|slider')
    # Color layer for popups/banners, generated from the stock dark stylesheet
    # with the grays shifted so the popup background lands on #121212.
    popup_scope=(--scope .popup-menu-boxpointer --scope '#notification-container'
                 --darken-grays 0.75 --gray-offset -23
                 --outside '#panel|login|unlock|overview|dash|workspace|app-grid|app-folder|\.osd|screenshot|Looking|\.lg-|switcher|keyboard|\.key\b|osk|-dialog|search|window-|ripple|pie-timer|lockDialog|candidate|page-indicator|page-navigation|edge-drag')
    make_shell() {
        local src="$1" theme="$2"; shift 2
        mkdir -p "$OUT/themes/$theme/gnome-shell"
        {
            echo "/* ggtk GNOME Shell theme (density: $DENSITY), generated from the"
            echo " * $shell_version stylesheet. GNOME Shell is LGPL-2.1-or-later."
            echo " * Re-run ./install.sh after upgrading GNOME Shell. */"
            compact "${shell_exclude[@]}" "$@" "$src"
            tweaks gnome-shell
            # Dark popups and notifications in both variants (see popups.css)
            python3 -I "$ROOT/scripts/compact.py" "${popup_scope[@]}" "$OUT/tmp/shell-dark.css"
            cat "$SRC/gnome-shell/popups.css"
        } >"$OUT/themes/$theme/gnome-shell/gnome-shell.css"
    }
    make_shell "$OUT/tmp/shell-light.css" "$NAME"
    make_shell "$OUT/tmp/shell-dark.css" "$NAME-dark" --full --darken-grays 0.75
fi

echo "$DENSITY" >"$OUT/DENSITY"
rm -rf "$OUT/tmp"

echo "Built $NAME and $NAME-dark (density: $DENSITY)"
echo "  libadwaita stylesheet: $source_desc"
echo "  app stylesheets mirrored: ${app_sheets:-0}"
echo "  GNOME Shell stylesheet: $shell_desc"
