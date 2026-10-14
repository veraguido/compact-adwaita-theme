#!/usr/bin/env python3
"""Generate "compact" override stylesheets from a GTK theme stylesheet.

Reads one or more compiled GTK CSS files (adw-gtk3, libadwaita, ...) and emits
a stylesheet that repeats every rule that sets a spacing or size property,
with the same selectors and in the same order, but with scaled-down values.

Mirroring the upstream selectors is what makes the result safe to load at a
higher priority (e.g. ~/.config/gtk-4.0/gtk.css): GTK lets a higher-priority
provider win regardless of specificity, so a hand-written `button { ... }`
rule would clobber every special case (.circular, .pill, .osd, ...). Here
each special case gets its own scaled copy, so the upstream cascade is kept.

Every rule that sets one of those properties is mirrored, even when its
values stay the same (see transform_rule).

With --full the whole stylesheet is re-emitted instead (used for GNOME Shell,
where a theme replaces the stock stylesheet rather than layering on top).
"""

import argparse
import math
import re
import sys

PAD_PROPS = {
    "padding", "padding-top", "padding-right", "padding-bottom", "padding-left",
    "margin", "margin-top", "margin-right", "margin-bottom", "margin-left",
    "border-spacing",
    "---group-padding",  # libadwaita toggle-group internal variable
    # GNOME Shell (St)
    "spacing", "spacing-rows", "spacing-columns",
    "-natural-hpadding", "-minimum-hpadding",
}
SIZE_PROPS = {"min-height", "min-width"}
RADIUS_PROPS = {
    "border-radius", "border-top-left-radius", "border-top-right-radius",
    "border-bottom-left-radius", "border-bottom-right-radius",
    "--window-radius",  # libadwaita
}

# Widgets whose spacing/size is geometry rather than padding: shrinking them
# breaks hit areas, slider alignment or shadows.
EXCLUDE = re.compile(
    r"scrollbar|slider|\bscale\b|drag-handle|shadow|(^|[\s>])decoration\b"
    r"|cursor-handle|paned|progressbar|levelbar|spinner|magnifier"
    r"|touch-selection|indicator|\.osd|\bborder\b"
)
# Widgets whose radius must stay tied to their (unscaled) size.
# (?<![\w-])name(?![\w-]) matches the widget name, not e.g. .switch-user-button
EXCLUDE_RADIUS = re.compile(
    r"(?<![\w-])(switch|check|radio|color)(?![\w-])|toggle-switch|circular|pill"
)

PX = re.compile(r"(?<![\w.])(-?\d*\.?\d+)px")
EM = re.compile(r"(?<![\w.])(-?\d*\.?\d+)em\b")
HEX = re.compile(r"#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b")


class Scaler:
    def __init__(self, pad, size, radius):
        self.pad = pad
        self.size = size
        self.radius = radius

    def pad_px(self, v):
        if v == 0:
            return v
        a = abs(v)
        r = max(1, math.floor(a * self.pad + 0.25))
        return math.copysign(r, v)

    def size_px(self, v):
        # Only interactive heights/widths (buttons, entries, rows, bars).
        # Icon-sized (<=22) and layout widths (>50) are left alone.
        if 22 < v <= 50:
            return round(16 + (v - 16) * self.size)
        return v

    def radius_px(self, v):
        # Tiny radii stay as they are; pill/circle values (>=99px) too.
        if v <= 4 or v >= 99:
            return v
        return max(3, math.floor(v * self.radius + 0.25))

    def pad_em(self, v):
        return round(v * self.pad, 3)


def darken_grays(value, factor):
    """Turn near-neutral dark/mid grays into darker, fully neutral grays."""
    def sub(m):
        h = m.group(1)
        if len(h) == 3:
            h = "".join(c * 2 for c in h)
        rgb = [int(h[i:i + 2], 16) for i in (0, 2, 4)]
        avg = sum(rgb) / 3
        if max(rgb) - min(rgb) > 8 or not 20 <= avg <= 110:
            return m.group(0)
        return "#{0:02x}{0:02x}{0:02x}".format(round(avg * factor))
    return HEX.sub(sub, value)


def fmt(v):
    v = float(v)
    return f"{int(v)}px" if v.is_integer() else f"{v:g}px"


def split_top(text, sep):
    """Split on `sep` outside of parentheses and quotes."""
    out, depth, quote, start = [], 0, None, 0
    for i, c in enumerate(text):
        if quote:
            if c == quote and text[i - 1] != "\\":
                quote = None
        elif c in "\"'":
            quote = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif c == sep and depth == 0:
            out.append(text[start:i])
            start = i + 1
    out.append(text[start:])
    return out


def parse(css, i=0, nested=False):
    """Tiny GTK-CSS parser: returns a list of
    ('stmt', text) | ('rule', selector, body) | ('block', prelude, items)."""
    items, start = [], i
    while i < len(css):
        c = css[i]
        if c in "\"'":
            i = css.index(c, i + 1)
        elif c == "{":
            prelude = " ".join(css[start:i].split())
            if prelude.startswith("@") and not prelude.startswith("@font-face"):
                sub, i = parse(css, i + 1, nested=True)
                items.append(("block", prelude, sub))
            else:
                j = css.index("}", i)
                items.append(("rule", prelude, css[i + 1:j]))
                i = j
            start = i + 1
        elif c == ";" and css[start:i].strip().startswith("@"):
            items.append(("stmt", css[start:i + 1].strip()))
            start = i + 1
        elif c == "}" and nested:
            return items, i
        i += 1
    return items, i


def transform_decl(prop, value, selector, s, geometry=True):
    """Scale one declaration. With geometry=False (excluded widgets) only the
    corner radius is scaled, so rounding stays consistent everywhere."""
    if not geometry and prop not in RADIUS_PROPS:
        return value
    if prop in PAD_PROPS:
        fn = s.pad_px
    elif prop in SIZE_PROPS:
        fn = s.size_px
    elif prop in RADIUS_PROPS:
        if EXCLUDE_RADIUS.search(selector):
            return value
        fn = s.radius_px
    else:
        return value
    value = PX.sub(lambda m: fmt(fn(float(m.group(1)))), value)
    if prop in PAD_PROPS:
        value = EM.sub(lambda m: f"{s.pad_em(float(m.group(1))):g}em", value)
    return value


TRACKED = PAD_PROPS | SIZE_PROPS | RADIUS_PROPS


def transform_rule(selector, body, s):
    """Return the rule(s) mirroring `selector` for every tracked property.

    Unchanged and excluded values are still emitted verbatim: when loaded at
    a higher priority, a more specific upstream rule must keep beating the
    scaled-down generic ones, exactly as it does upstream.
    """
    decls = []
    for decl in split_top(body, ";"):
        if ":" not in decl:
            continue
        prop, value = decl.split(":", 1)
        prop, value = prop.strip(), " ".join(value.split())
        if prop in TRACKED:
            decls.append((prop, value))
    if not decls:
        return []

    selectors = [x.strip() for x in split_top(selector, ",")]
    keep = [x for x in selectors if EXCLUDE.search(x)]
    scale = [x for x in selectors if not EXCLUDE.search(x)]
    out = []
    if scale:
        sel = ", ".join(scale)
        body = " ".join(f"{p}: {transform_decl(p, v, sel, s)};" for p, v in decls)
        out.append(f"{sel} {{ {body} }}")
    if keep:
        sel = ", ".join(keep)
        body = " ".join(f"{p}: {transform_decl(p, v, sel, s, False)};" for p, v in decls)
        out.append(f"{sel} {{ {body} }}")
    return out


def split_decls(body):
    for decl in split_top(body, ";"):
        if ":" in decl:
            prop, value = decl.split(":", 1)
            yield prop.strip(), " ".join(value.split())


def full_rule(selector, body, s, darken):
    """Re-emit a whole rule, scaling tracked properties."""
    def render(sel, scale):
        decls = []
        for p, v in split_decls(body):
            v = transform_decl(p, v, sel, s, scale)
            if darken:
                v = darken_grays(v, darken)
            decls.append(f"  {p}: {v};")
        return f"{sel} {{\n" + "\n".join(decls) + "\n}"

    selectors = [x.strip() for x in split_top(selector, ",")]
    keep = [x for x in selectors if EXCLUDE.search(x)]
    scale = [x for x in selectors if not EXCLUDE.search(x)]
    out = []
    if scale:
        out.append(render(",\n".join(scale), True))
    if keep:
        out.append(render(",\n".join(keep), False))
    return out


def emit_full(items, s, darken):
    out = []
    for item in items:
        if item[0] == "stmt":
            out.append(item[1])
        elif item[0] == "rule":
            out.extend(full_rule(item[1], item[2], s, darken))
        else:
            inner = emit_full(item[2], s, darken)
            out.append(item[1] + " {\n" + "\n".join(inner) + "\n}")
    return out


def emit(items, s):
    out = []
    for item in items:
        if item[0] == "rule":
            out.extend(transform_rule(item[1], item[2], s))
        elif item[0] == "block":
            prelude = item[1]
            if prelude.startswith(("@media", "@supports")):
                inner = emit(item[2], s)
                if inner:
                    out.append(prelude + " {\n" + "\n".join(inner) + "\n}")
            # @keyframes and friends are left alone
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("inputs", nargs="+", help="source stylesheets")
    ap.add_argument("-o", "--output", default="-")
    ap.add_argument("--pad-scale", type=float, default=0.5,
                    help="factor for padding/margin/spacing (default 0.5)")
    ap.add_argument("--size-scale", type=float, default=0.55,
                    help="factor for the part of min-height/min-width above 16px")
    ap.add_argument("--radius-scale", type=float, default=0.5,
                    help="factor for corner radii between 5px and 98px")
    ap.add_argument("--full", action="store_true",
                    help="re-emit the whole stylesheet instead of overrides")
    ap.add_argument("--exclude", action="append", default=[],
                    help="extra selector regex to leave unscaled (repeatable)")
    ap.add_argument("--darken-grays", type=float, default=0,
                    help="with --full: multiply neutral dark grays by this factor")
    args = ap.parse_args()

    global EXCLUDE
    if args.exclude:
        EXCLUDE = re.compile("|".join([EXCLUDE.pattern, *args.exclude]))

    s = Scaler(args.pad_scale, args.size_scale, args.radius_scale)
    chunks = []
    for path in args.inputs:
        with open(path, encoding="utf-8") as f:
            css = re.sub(r"/\*.*?\*/", "", f.read(), flags=re.S)
        items, _ = parse(css)
        rules = emit_full(items, s, args.darken_grays) if args.full else emit(items, s)
        chunks.append(f"/* from {path.rsplit('/', 1)[-1]} */\n" + "\n".join(rules))

    header = (
        "/* Generated by ggtk scripts/compact.py -- do not edit.\n"
        f" * pad-scale={args.pad_scale} size-scale={args.size_scale}"
        f" radius-scale={args.radius_scale} */\n"
    )
    text = header + "\n\n".join(chunks) + "\n"
    if args.output == "-":
        sys.stdout.write(text)
    else:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(text)


if __name__ == "__main__":
    main()
