#!/usr/bin/env bash
# Remove ggtk completely.
#
# Usage: ./uninstall.sh [options]
#
# Removes the per-user and (if present) system-wide themes, the libadwaita
# override, the Flatpak permissions ggtk added, and the build output. GTK and
# GNOME Shell theme settings that still point at ggtk are reset to the default.
#
# Options:
#   --keep-settings   don't reset the gtk-theme / shell theme settings
#   --keep-build      don't delete ./build
#   -h, --help        show this help
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="ggtk"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
GTK4_CSS="$CONFIG_HOME/gtk-4.0/gtk.css"
SHELL_THEME_KEY="/org/gnome/shell/extensions/user-theme/name"

KEEP_SETTINGS=0
KEEP_BUILD=0

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }
info() { printf '\033[1;34m::\033[0m %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-settings) KEEP_SETTINGS=1; shift ;;
        --keep-build) KEEP_BUILD=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; echo "uninstall.sh: unknown argument: $1" >&2; exit 1 ;;
    esac
done

is_ggtk() { [[ "$1" == "'$NAME'" || "$1" == "'$NAME-dark'" ]]; }

# Reset settings first, so nothing keeps pointing at a theme that's gone.
if [[ $KEEP_SETTINGS -eq 0 ]]; then
    current="$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null || true)"
    if is_ggtk "$current"; then
        info "Resetting GTK theme (was $current)"
        gsettings reset org.gnome.desktop.interface gtk-theme
    fi
    current="$(dconf read "$SHELL_THEME_KEY" 2>/dev/null || true)"
    if is_ggtk "$current"; then
        info "Resetting GNOME Shell theme (was $current)"
        dconf reset "$SHELL_THEME_KEY"
    fi
fi

args=(uninstall)
if [[ -d /usr/share/themes/$NAME || -d /usr/share/themes/$NAME-dark ]]; then
    info "System-wide install found; removing it too (uses sudo)"
    args+=(--system)
fi
"$ROOT/install.sh" "${args[@]}"

# The backup of gtk.css is redundant once the file is back to its original.
backup="$GTK4_CSS.$NAME-backup"
if [[ -f "$backup" ]] && { [[ ! -e "$GTK4_CSS" ]] || cmp -s "$backup" "$GTK4_CSS"; }; then
    if [[ ! -e "$GTK4_CSS" ]]; then
        mv "$backup" "$GTK4_CSS"
        info "Restored $GTK4_CSS from backup"
    else
        rm -f "$backup"
        info "Removed redundant backup $backup"
    fi
fi

if [[ $KEEP_BUILD -eq 0 && -d "$ROOT/build" ]]; then
    info "Removing build output"
    rm -rf "${ROOT:?}/build"
fi

info "ggtk has been removed. Log out and back in (or restart apps) to see the change."
