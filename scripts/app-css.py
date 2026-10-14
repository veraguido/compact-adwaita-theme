#!/usr/bin/env python3
"""Collect the stylesheets that installed GTK4 apps bundle in their GResources.

libadwaita apps load their own style.css at "application" priority, above the
theme. The ggtk override in ~/.config/gtk-4.0/gtk.css sits at "user" priority,
above both, so its mirrored generic rules (button, entry, ...) would otherwise
beat the apps' own styling (e.g. the round accent buttons in Settings). This
script gathers those app stylesheets so build.sh can mirror them too.

Writes one CSS file per app stylesheet into OUTDIR and prints a summary.
Dark/high-contrast variants are skipped: they only change colors.
"""

import glob
import os
import subprocess
import sys

SEARCH = [
    "/usr/bin/*", "/usr/libexec/*", "/usr/libexec/*/*", "/usr/lib64/*/*.so*",
    "/usr/lib/*/*.so*",
    "/var/lib/flatpak/app/*/current/active/files/bin/*",
    "/var/lib/flatpak/app/*/current/active/files/libexec/*",
    os.path.expanduser("~/.local/share/flatpak/app/*/current/active/files/bin/*"),
]
SKIP_SUFFIXES = ("-dark.css", "-hc.css", "-hc-dark.css", "-dark-hc.css")
# The toolkit's own stylesheets are already handled by build.sh.
SKIP_PREFIXES = ("/org/gnome/Adwaita/", "/org/gtk/libgtk/")
# Bundled CSS that isn't a GTK widget stylesheet (web pages, code templates).
SKIP_PARTS = ("page-templates", "highlightjs", "readability", "templates/", "/demo")


def has_resources(path):
    try:
        if not os.path.isfile(path) or os.path.getsize(path) > 300 * 1024 * 1024:
            return False
        with open(path, "rb") as f:
            if f.read(4) != b"\x7fELF":
                return False
            data = f.read()
            return b"GVariant" in data and b"libgtk-4.so" in data
    except OSError:
        return False


def main():
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)
    seen, seen_css = set(), set()
    count = 0
    for pattern in SEARCH:
        for path in sorted(glob.glob(pattern)):
            real = os.path.realpath(path)
            if real in seen or not has_resources(real):
                continue
            seen.add(real)
            res = subprocess.run(["gresource", "list", real], capture_output=True, text=True)
            for name in res.stdout.split():
                if not name.endswith(".css") or name.endswith(SKIP_SUFFIXES):
                    continue
                if name.startswith(SKIP_PREFIXES) or any(p in name for p in SKIP_PARTS):
                    continue
                css = subprocess.run(["gresource", "extract", real, name],
                                     capture_output=True).stdout
                if not css.strip() or css in seen_css:
                    continue
                seen_css.add(css)
                count += 1
                safe = name.strip("/").replace("/", "_")
                with open(os.path.join(outdir, f"{count:03d}-{safe}"), "wb") as f:
                    f.write(css)
    validate(outdir)
    print(len(os.listdir(outdir)))


def validate(outdir):
    """Drop stylesheets GTK4 can't parse cleanly, if PyGObject is available."""
    try:
        import gi
        gi.require_version("Gtk", "4.0")
        from gi.repository import Gtk
    except (ImportError, ValueError):
        return
    for name in os.listdir(outdir):
        path = os.path.join(outdir, name)
        errors = []
        provider = Gtk.CssProvider()
        provider.connect("parsing-error", lambda *a: errors.append(a))
        provider.load_from_path(path)
        if errors:
            os.remove(path)


if __name__ == "__main__":
    main()
