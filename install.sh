#!/usr/bin/env bash
# Install or remove the ggtk GTK3/GTK4/libadwaita theme.
#
# Usage: ./install.sh [install|uninstall|status] [options]
#
# Options:
#   --system           install themes to /usr/share/themes (uses sudo)
#                      instead of ~/.local/share/themes
#   --density PRESET   dense (default), compact or mild
#   --no-libadwaita    don't touch ~/.config/gtk-4.0 (libadwaita apps)
#   --no-flatpak       don't add Flatpak filesystem overrides
#   -h, --help         show this help
#
# The libadwaita override is always per user, even with --system.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="ggtk"
THEMES=("$NAME" "$NAME-dark")

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$NAME"
STATE_FILE="$STATE_DIR/install-state"

USER_THEME_DIR="$DATA_HOME/themes"
SYSTEM_THEME_DIR="/usr/share/themes"
GTK4_DIR="$CONFIG_HOME/gtk-4.0"
GTK4_CSS="$GTK4_DIR/gtk.css"
GTK4_OVERRIDE="$GTK4_DIR/$NAME.css"
FLATPAK_OVERRIDES="${FLATPAK_USER_DIR:-$DATA_HOME/flatpak}/overrides/global"

BEGIN_MARK="/* >>> $NAME >>> managed by $NAME install.sh, remove with: ./install.sh uninstall */"
END_MARK="/* <<< $NAME <<< */"

ACTION="install"
SYSTEM=0
LIBADWAITA=1
FLATPAK=1
DENSITY="dense"

USER_THEME_EXT="user-theme@gnome-shell-extensions.gcampax.github.com"
SHELL_THEME_KEY="/org/gnome/shell/extensions/user-theme/name"

# --- helpers ----------------------------------------------------------------

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }
info() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

as_root() {
    if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

state_get() {
    [[ -f "$STATE_FILE" ]] && sed -n "s/^$1=//p" "$STATE_FILE" | tail -n1 || true
}

state_set() {
    mkdir -p "$STATE_DIR"
    touch "$STATE_FILE"
    sed -i "/^$1=/d" "$STATE_FILE"
    echo "$1=$2" >>"$STATE_FILE"
}

# Remove the managed block (markers included) from a file, in place.
strip_block() {
    local file="$1" tmp
    tmp="$(mktemp)"
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip { print }
    ' "$file" >"$tmp"
    cat "$tmp" >"$file"
    rm -f "$tmp"
}

# --- themes -----------------------------------------------------------------

install_themes() {
    local dest="$1" t
    info "Installing themes to $dest"
    for t in "${THEMES[@]}"; do
        if [[ $SYSTEM -eq 1 ]]; then
            as_root rm -rf "$dest/$t"
            as_root mkdir -p "$dest"
            as_root cp -r "$ROOT/build/themes/$t" "$dest/$t"
            as_root chmod -R a+rX "$dest/$t"
        else
            mkdir -p "$dest"
            rm -rf "${dest:?}/$t"
            cp -r "$ROOT/build/themes/$t" "$dest/$t"
        fi
    done
}

remove_themes() {
    local dest="$1" root="$2" t
    for t in "${THEMES[@]}"; do
        # Only remove directories that are actually ours.
        [[ -f "$dest/$t/index.theme" ]] || continue
        grep -q "^GtkTheme=$t\$" "$dest/$t/index.theme" || continue
        info "Removing $dest/$t"
        if [[ $root -eq 1 ]]; then as_root rm -rf "$dest/$t"; else rm -rf "${dest:?}/$t"; fi
    done
}

# --- libadwaita (~/.config/gtk-4.0/gtk.css) ---------------------------------

install_libadwaita() {
    info "Installing libadwaita override to $GTK4_OVERRIDE"
    if [[ -L "$GTK4_CSS" ]]; then
        warn "$GTK4_CSS is a symlink (managed by another tool?); not editing it."
        warn "Add this line at the very top of it yourself:  @import url(\"$NAME.css\");"
        mkdir -p "$GTK4_DIR"
        cp "$ROOT/build/libadwaita/$NAME.css" "$GTK4_OVERRIDE"
        return
    fi

    mkdir -p "$GTK4_DIR"
    cp "$ROOT/build/libadwaita/$NAME.css" "$GTK4_OVERRIDE"

    if [[ ! -e "$GTK4_CSS" ]]; then
        state_set created_gtk_css 1
        : >"$GTK4_CSS"
    elif ! grep -qF "$BEGIN_MARK" "$GTK4_CSS" && [[ ! -e "$GTK4_CSS.$NAME-backup" ]]; then
        cp "$GTK4_CSS" "$GTK4_CSS.$NAME-backup"
        info "Backed up existing gtk.css to $GTK4_CSS.$NAME-backup"
    fi

    # @import rules must come before any other rule, so the block goes first.
    strip_block "$GTK4_CSS"
    local tmp
    tmp="$(mktemp)"
    {
        echo "$BEGIN_MARK"
        echo "@import url(\"$NAME.css\");"
        echo "$END_MARK"
        cat "$GTK4_CSS"
    } >"$tmp"
    cat "$tmp" >"$GTK4_CSS"
    rm -f "$tmp"
}

remove_libadwaita() {
    if [[ -f "$GTK4_CSS" && ! -L "$GTK4_CSS" ]] && grep -qF "$BEGIN_MARK" "$GTK4_CSS"; then
        info "Removing $NAME import from $GTK4_CSS"
        strip_block "$GTK4_CSS"
        if [[ "$(state_get created_gtk_css)" == 1 ]] && ! grep -q '[^[:space:]]' "$GTK4_CSS"; then
            rm -f "$GTK4_CSS"
        fi
    elif [[ -L "$GTK4_CSS" ]] && grep -qF "$NAME.css" "$GTK4_CSS" 2>/dev/null; then
        warn "$GTK4_CSS is a symlink; remove the @import of $NAME.css from it yourself."
    fi
    if [[ -f "$GTK4_OVERRIDE" ]]; then
        info "Removing $GTK4_OVERRIDE"
        rm -f "$GTK4_OVERRIDE"
    fi
    if [[ -f "$GTK4_CSS.$NAME-backup" ]]; then
        info "Your original gtk.css is kept at $GTK4_CSS.$NAME-backup"
    fi
}

# --- Flatpak ----------------------------------------------------------------

# Print the filesystems= entries of the global user override, one per line.
flatpak_filesystems() {
    [[ -f "$FLATPAK_OVERRIDES" ]] || return 0
    awk -F= '
        /^\[/ { ctx = ($0 == "[Context]") }
        ctx && $1 == "filesystems" { print substr($0, index($0, "=") + 1) }
    ' "$FLATPAK_OVERRIDES" | tr ';' '\n' | sed '/^$/d'
}

install_flatpak() {
    command -v flatpak >/dev/null || return 0
    local wanted=() added=() current fs
    [[ $SYSTEM -eq 0 ]] && wanted+=("xdg-data/themes:ro")
    [[ $LIBADWAITA -eq 1 ]] && wanted+=("xdg-config/gtk-4.0:ro")
    [[ ${#wanted[@]} -gt 0 ]] || return 0

    current="$(flatpak_filesystems)"
    for fs in "${wanted[@]}"; do
        # Already granted (with any access mode)? Then leave it alone.
        if grep -qxE "${fs%:ro}(:r[ow]|:create)?" <<<"$current"; then
            continue
        fi
        info "Granting Flatpak apps read access to ${fs%:ro}"
        flatpak override --user --filesystem="$fs"
        added+=("$fs")
    done

    if [[ ${#added[@]} -gt 0 ]]; then
        state_set flatpak_added "$(state_get flatpak_added)$(printf '%s;' "${added[@]}")"
    fi
    if [[ $SYSTEM -eq 1 ]]; then
        warn "Flatpak apps cannot see $SYSTEM_THEME_DIR; GTK3 Flatpak apps need a per-user install."
    fi
}

remove_flatpak() {
    local added fs tmp
    added="$(state_get flatpak_added)"
    [[ -n "$added" && -f "$FLATPAK_OVERRIDES" ]] || return 0
    info "Removing Flatpak overrides added by $NAME: ${added%;}"
    tmp="$(mktemp)"
    awk -F= -v drop="$added" '
        BEGIN { n = split(drop, d, ";"); for (i = 1; i <= n; i++) if (d[i] != "") rm[d[i]] = 1 }
        /^\[/ { ctx = ($0 == "[Context]") }
        ctx && $1 == "filesystems" {
            m = split(substr($0, index($0, "=") + 1), f, ";"); out = ""
            for (i = 1; i <= m; i++) if (f[i] != "" && !(f[i] in rm)) out = out f[i] ";"
            if (out != "") print "filesystems=" out
            next
        }
        { print }
    ' "$FLATPAK_OVERRIDES" >"$tmp"
    cat "$tmp" >"$FLATPAK_OVERRIDES"
    rm -f "$tmp"
    state_set flatpak_added ""
}

# --- actions ----------------------------------------------------------------

do_install() {
    "$ROOT/build.sh" --density "$DENSITY"

    if [[ $SYSTEM -eq 1 ]]; then
        install_themes "$SYSTEM_THEME_DIR"
    else
        install_themes "$USER_THEME_DIR"
    fi
    [[ $LIBADWAITA -eq 1 ]] && install_libadwaita
    [[ $FLATPAK -eq 1 ]] && install_flatpak

    echo
    info "Done. To use it:"
    echo "   gsettings set org.gnome.desktop.interface gtk-theme '$NAME-dark'   # or '$NAME'"
    echo "   gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'"
    [[ $LIBADWAITA -eq 1 ]] && echo "   Restart running apps to pick up the libadwaita override."
    if [[ -f "$ROOT/build/themes/$NAME/gnome-shell/gnome-shell.css" ]]; then
        echo
        info "GNOME Shell theme (needs the User Themes extension):"
        if ! gnome-extensions info "$USER_THEME_EXT" >/dev/null 2>&1; then
            echo "   Install it first: https://extensions.gnome.org/extension/19/user-themes/"
            echo "   (Fedora: sudo dnf install gnome-shell-extension-user-theme)"
        fi
        echo "   gnome-extensions enable $USER_THEME_EXT"
        echo "   dconf write $SHELL_THEME_KEY \"'$NAME'\"        # follows light/dark, stock colors"
        echo "   dconf write $SHELL_THEME_KEY \"'$NAME-dark'\"   # always dark, darker palette"
        echo "   Re-run ./install.sh after upgrading GNOME Shell."
    fi
    return 0
}

do_uninstall() {
    remove_themes "$USER_THEME_DIR" 0
    if [[ $SYSTEM -eq 1 ]]; then
        remove_themes "$SYSTEM_THEME_DIR" 1
    elif [[ -d "$SYSTEM_THEME_DIR/$NAME" ]]; then
        warn "A system-wide install exists; remove it with: ./install.sh uninstall --system"
    fi
    [[ $LIBADWAITA -eq 1 ]] && remove_libadwaita
    [[ $FLATPAK -eq 1 ]] && remove_flatpak

    if [[ $SYSTEM -eq 1 || ! -d "$SYSTEM_THEME_DIR/$NAME" ]]; then
        rm -rf "$STATE_DIR"
    fi

    local current
    current="$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null || true)"
    if [[ "$current" == "'$NAME'" || "$current" == "'$NAME-dark'" ]]; then
        warn "Your GTK theme is still set to $current. Reset it with:"
        echo "   gsettings reset org.gnome.desktop.interface gtk-theme"
    fi
    current="$(dconf read "$SHELL_THEME_KEY" 2>/dev/null || true)"
    if [[ "$current" == "'$NAME'" || "$current" == "'$NAME-dark'" ]]; then
        warn "Your GNOME Shell theme is still set to $current. Reset it with:"
        echo "   dconf reset $SHELL_THEME_KEY"
    fi
    info "Done."
}

do_status() {
    local t d
    for d in "$USER_THEME_DIR" "$SYSTEM_THEME_DIR"; do
        for t in "${THEMES[@]}"; do
            [[ -d "$d/$t" ]] && echo "theme:      $d/$t"
        done
    done
    if [[ -f "$GTK4_CSS" ]] && grep -qF "$BEGIN_MARK" "$GTK4_CSS"; then
        echo "libadwaita: $GTK4_OVERRIDE (imported from $GTK4_CSS)"
    else
        echo "libadwaita: not installed"
    fi
    echo "flatpak:    $(state_get flatpak_added || true)"
    echo "gtk-theme:  $(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null || echo '?')"
    echo "shell:      $(dconf read "$SHELL_THEME_KEY" 2>/dev/null | grep . || echo default) (User Themes)"
}

# --- main -------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        install|uninstall|remove|status) ACTION="$1"; shift ;;
        --system) SYSTEM=1; shift ;;
        --density) [[ $# -ge 2 ]] || die "--density needs a value"; DENSITY="$2"; shift 2 ;;
        --no-libadwaita) LIBADWAITA=0; shift ;;
        --no-flatpak) FLATPAK=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

[[ $EUID -eq 0 && $SYSTEM -eq 0 ]] && die "don't run as root; use --system for a system-wide install"

case "$ACTION" in
    install) do_install ;;
    uninstall|remove) do_uninstall ;;
    status) do_status ;;
esac
