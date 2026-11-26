#!/usr/bin/env python3
"""Builds the "ArcOS Sonora" icon theme (SVG, drawn in the ArcOS pastel-gradient style).

   python3 arcos_icons.py OUTPUT_DIR      writes OUTPUT_DIR/index.theme and the icons

Only the icons ArcOS redesigns are in the theme. Everything else falls back to Papirus.
The SVGs use plain shapes and gradients only, so they render the same in Qt and GTK.
"""
import math
import os
import sys

# ---------------------------------------------------------------- building blocks
def squircle(gid, c1, c2, c3=None):
    """Rounded tile with a gradient, a soft lower edge and a glassy top highlight."""
    stops = '<stop offset="0" stop-color="%s"/>' % c1
    if c3:
        stops += '<stop offset="0.55" stop-color="%s"/><stop offset="1" stop-color="%s"/>' % (c2, c3)
    else:
        stops += '<stop offset="1" stop-color="%s"/>' % c2
    defs = ('<linearGradient id="%s" x1="0.1" y1="0" x2="0.9" y2="1">%s</linearGradient>'
            '<linearGradient id="%s-hi" x1="0" y1="0" x2="0" y2="1">'
            '<stop offset="0" stop-color="#ffffff" stop-opacity="0.38"/>'
            '<stop offset="1" stop-color="#ffffff" stop-opacity="0"/></linearGradient>' % (gid, stops, gid))
    body = ('<rect x="8" y="11" width="112" height="112" rx="29" fill="#1b1d3a" opacity="0.18"/>'
            '<rect x="8" y="8" width="112" height="112" rx="29" fill="url(#%s)"/>'
            '<rect x="8" y="8" width="112" height="56" rx="29" fill="url(#%s-hi)"/>'
            '<rect x="8.5" y="8.5" width="111" height="111" rx="28.5" fill="none" stroke="#ffffff" '
            'stroke-opacity="0.35"/>' % (gid, gid))
    return defs, body


def svg(defs, body):
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">'
            '<defs>%s</defs>%s</svg>\n' % (defs, body))


# ---------------------------------------------------------------- app icons
def icon_arcos():
    d, b = squircle("a", "#3fd0ff", "#2f7dff", "#7b3df5")
    arc = ('<path d="M27 86 Q64 18 101 86" fill="none" stroke="#ffffff" stroke-width="9" stroke-linecap="round"/>'
           '<path d="M50 92 Q76 66 102 90" fill="none" stroke="#ffffff" stroke-opacity="0.45" '
           'stroke-width="4.5" stroke-linecap="round"/>')
    return svg(d, b + arc)


def icon_gear():
    d, b = squircle("g", "#a29fbe", "#6c6889", "#4c4868")
    pts = []
    for i in range(8):
        a = math.radians(i * 45)
        for da, r in ((-17, 28), (-10, 37), (10, 37), (17, 28)):
            t = a + math.radians(da)
            pts.append((64 + r * math.sin(t), 64 - r * math.cos(t)))
    path = "M" + " L".join("%.1f %.1f" % p for p in pts) + " Z"
    hole = "M64 52 a12 12 0 1 0 0.01 0 Z"
    gear = '<path d="%s %s" fill="#f4f3ff" fill-rule="evenodd" fill-opacity="0.95"/>' % (path, hole)
    ring = '<circle cx="64" cy="64" r="6" fill="#6c6889"/>'
    return svg(d, b + gear + ring)


def icon_terminal():
    d, b = squircle("t", "#383a4d", "#20212d", "#12131a")
    g = ('<path d="M36 48 L58 64 L36 80" fill="none" stroke="#ffffff" stroke-width="8" '
         'stroke-linecap="round" stroke-linejoin="round"/>'
         '<path d="M68 82 H92" fill="none" stroke="#ffffff" stroke-width="8" stroke-linecap="round"/>')
    return svg(d, b + g)


def icon_trash(full=False):
    d, b = squircle("r", "#f6f4ff", "#dcd9f4", "#bdb9e6")
    c = "#6f6a95"
    g = ('<path d="M42 50 H86 L82 98 Q81.5 104 76 104 H52 Q46.5 104 46 98 Z" fill="%s" fill-opacity="0.9"/>'
         '<rect x="38" y="42" width="52" height="7" rx="3.5" fill="%s"/>'
         '<rect x="54" y="35" width="20" height="8" rx="4" fill="%s"/>'
         '<path d="M56 58 V94 M64 58 V94 M72 58 V94" stroke="#ffffff" stroke-opacity="0.55" '
         'stroke-width="3.2" stroke-linecap="round"/>' % (c, c, c))
    if full:
        g += '<path d="M48 46 L56 36 L66 44 L76 34 L82 44" fill="none" stroke="%s" stroke-width="3" ' \
             'stroke-linecap="round" stroke-linejoin="round" opacity="0.8"/>' % c
    return svg(d, b + g)


def icon_globe():
    d, b = squircle("w", "#4ad6ff", "#2c86ff", "#3f5cf0")
    s = 'fill="none" stroke="#ffffff" stroke-width="5" stroke-linecap="round"'
    g = ('<circle cx="64" cy="64" r="34" %s/><ellipse cx="64" cy="64" rx="15" ry="34" %s/>'
         '<path d="M30 64 H98 M36 46 H92 M36 82 H92" %s/>' % (s, s, s))
    return svg(d, b + g)


def icon_monitor():
    d, b = squircle("m", "#1f3550", "#17283f", "#0e1a2b")
    g = ('<path d="M32 66 H48 L56 48 L66 84 L74 60 L80 66 H96" fill="none" stroke="#48e0b0" '
         'stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>')
    return svg(d, b + g)


def icon_calculator():
    d, b = squircle("c", "#4d4a66", "#32304a", "#1f1d33")
    keys = ""
    for r in range(3):
        for c in range(3):
            col = "#ff9f43" if c == 2 else "#d8d6ee"
            keys += '<rect x="%d" y="%d" width="14" height="11" rx="4" fill="%s"/>' % (35 + c * 19, 62 + r * 16, col)
    g = '<rect x="34" y="30" width="60" height="22" rx="6" fill="#9fe6d0" fill-opacity="0.9"/>' + keys
    return svg(d, b + g)


# ---------------------------------------------------------------- folders
def folder(gid, glyph=""):
    defs = ('<linearGradient id="%sb" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#4cb7ff"/>'
            '<stop offset="1" stop-color="#2a7df5"/></linearGradient>'
            '<linearGradient id="%sf" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#8ad9ff"/>'
            '<stop offset="1" stop-color="#3b97ff"/></linearGradient>' % (gid, gid))
    body = ('<path d="M12 40 Q12 28 24 28 H50 L60 38 H104 Q116 38 116 50 V100 Q116 110 106 110 H22 Q12 110 12 100 Z" '
            'fill="#1b1d3a" opacity="0.16" transform="translate(0 3)"/>'
            '<path d="M12 38 Q12 26 24 26 H50 L60 36 H104 Q116 36 116 48 V98 Q116 108 106 108 H22 Q12 108 12 98 Z" '
            'fill="url(#%sb)"/>'
            '<rect x="12" y="46" width="104" height="62" rx="11" fill="url(#%sf)"/>'
            '<rect x="12.5" y="46.5" width="103" height="61" rx="10.5" fill="none" stroke="#ffffff" '
            'stroke-opacity="0.45"/>' % (gid, gid))
    return svg(defs, body + glyph)


GLYPH = 'fill="none" stroke="#1a55d0" stroke-opacity="0.9" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"'


def folder_glyphs():
    return {
        "folder": "",
        "folder-download": '<path d="M64 60 V88 M52 78 L64 90 L76 78 M50 98 H78" %s/>' % GLYPH,
        "folder-documents": '<path d="M50 58 H70 L80 68 V98 H50 Z M70 58 V68 H80 M56 80 H74 M56 88 H74" %s/>' % GLYPH,
        "folder-music": '<path d="M76 60 V88 M76 60 L58 66 V92 M58 92 a6 5 0 1 1 -0.1 0 M76 88 a6 5 0 1 1 -0.1 0" %s/>' % GLYPH,
        "folder-pictures": '<rect x="46" y="58" width="36" height="34" rx="5" %s/><path d="M48 88 L60 76 L68 84 L74 78 L82 88" %s/>' % (GLYPH, GLYPH),
        "folder-videos": '<rect x="48" y="58" width="32" height="36" rx="5" %s/><path d="M48 70 H80 M48 82 H80 M58 58 V94 M70 58 V94" %s/>' % (GLYPH, GLYPH),
        "user-home": '<path d="M44 78 L64 58 L84 78 M50 74 V96 H78 V74 M60 96 V84 H68 V96" %s/>' % GLYPH,
        "user-desktop": '<rect x="44" y="58" width="40" height="28" rx="5" %s/><path d="M56 96 H72 M64 86 V96" %s/>' % (GLYPH, GLYPH),
    }


# ---------------------------------------------------------------- arc logo for the menu bar
def logo_line(color):
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">'
            '<path d="M3.2 17.6 Q12 1.2 20.8 17.6" fill="none" stroke="%s" stroke-width="2.6" stroke-linecap="round"/>'
            '<path d="M9 18.6 Q13.6 13 20.2 18.2" fill="none" stroke="%s" stroke-opacity="0.55" stroke-width="1.6" '
            'stroke-linecap="round"/></svg>\n' % (color, color))


# ---------------------------------------------------------------- theme
APPS = {
    "arcos": icon_arcos, "org.arcos.shell": icon_arcos,
    "system-file-manager": icon_arcos, "org.xfce.thunar": icon_arcos, "thunar": icon_arcos,
    "preferences-system": icon_gear, "org.arcos.settings": icon_gear, "arcos-settings": icon_gear,
    "utilities-terminal": icon_terminal, "foot": icon_terminal, "org.codeberg.dnkl.foot": icon_terminal,
    "web-browser": icon_globe, "internet-web-browser": icon_globe,
    "utilities-system-monitor": icon_monitor, "accessories-calculator": icon_calculator,
}

INDEX = """[Icon Theme]
Name=ArcOS Sonora
Comment=Icons for ArcOS Sonora, made by Fuzion
Inherits=Papirus,hicolor
Directories=scalable/apps,scalable/places,scalable/mimetypes

[scalable/apps]
Size=128
MinSize=16
MaxSize=512
Type=Scalable
Context=Applications

[scalable/places]
Size=128
MinSize=16
MaxSize=512
Type=Scalable
Context=Places

[scalable/mimetypes]
Size=128
MinSize=16
MaxSize=512
Type=Scalable
Context=MimeTypes
"""


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def build(out):
    write(os.path.join(out, "index.theme"), INDEX)
    for name, fn in APPS.items():
        write(os.path.join(out, "scalable", "apps", name + ".svg"), fn())
    for name, glyph in folder_glyphs().items():
        write(os.path.join(out, "scalable", "places", name + ".svg"), folder("f" + name.replace("-", ""), glyph))
    write(os.path.join(out, "scalable", "mimetypes", "inode-directory.svg"), folder("fdir"))
    write(os.path.join(out, "scalable", "places", "user-trash.svg"), icon_trash(False))
    write(os.path.join(out, "scalable", "places", "user-trash-full.svg"), icon_trash(True))
    # the menu bar logo (the arc line only)
    write(os.path.join(out, "logo", "arc-logo-black.svg"), logo_line("#000000"))
    write(os.path.join(out, "logo", "arc-logo-white.svg"), logo_line("#ffffff"))


if __name__ == "__main__":
    build(sys.argv[1] if len(sys.argv) > 1 else "ArcOS-Sonora")
