"""Shared helpers for the ArcOS Sonora apps (launcher, arc menu, settings)."""
import os

HOME = os.path.expanduser("~")
CFG = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.join(HOME, ".config")), "arcos")
CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.join(HOME, ".cache")), "arcos")

ACCENTS = {   # same names GNOME / libadwaita use
    "blue": "#3584e4", "teal": "#2190a4", "green": "#3a944a", "yellow": "#c88800",
    "orange": "#ed5b00", "red": "#e62d42", "pink": "#d56199", "purple": "#9141ac",
    "slate": "#6f8396",
}


def read_text(path, default=""):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return default


def mode():
    return "light" if read_text(os.path.join(CFG, "mode"), "dark") == "light" else "dark"


def accent():
    a = read_text(os.path.join(CFG, "accent"), ACCENTS["blue"])
    return a if a.startswith("#") and len(a) in (4, 7) else ACCENTS["blue"]


# --- Icons: simple outline icons, drawn in the right color for dark / light mode -------------
_ICONS = {
    "search": '<circle cx="11" cy="11" r="6.5"/><path d="M16 16l5 5"/>',
    "apps": '<rect x="3.5" y="3.5" width="7" height="7" rx="2"/><rect x="13.5" y="3.5" width="7" height="7" rx="2"/>'
            '<rect x="3.5" y="13.5" width="7" height="7" rx="2"/><path d="M17 13.5v7M13.5 17h7"/>',
    "folder": '<path d="M3 7.5A2.5 2.5 0 0 1 5.5 5H9l2 2.2h7.5A2.5 2.5 0 0 1 21 9.7v7.8A2.5 2.5 0 0 1 18.5 20h-13A2.5 2.5 0 0 1 3 17.5z"/>',
    "clipboard": '<rect x="8.5" y="3.5" width="11" height="14" rx="2.2"/><path d="M5.5 7.5v10.2A2.8 2.8 0 0 0 8.3 20.5H16"/>',
    "minus": '<circle cx="12" cy="12" r="8.5"/><path d="M8 12h8"/>',
}


def icon_path(name, size=24):
    """Path to an SVG icon file for the current dark / light mode (created on first use)."""
    m = mode()
    color = "#ffffff" if m == "dark" else "#1c1c28"
    d = os.path.join(CACHE, "icons", m)
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, name + ".svg")
    if not os.path.exists(p):
        svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 24 24" fill="none" '
               'stroke="%s" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">%s</svg>'
               % (size, size, color, _ICONS[name]))
        with open(p, "w", encoding="utf-8") as f:
            f.write(svg)
    return p


def glass_css():
    """Stylesheet shared by the launcher and the arc menu."""
    m, a = mode(), accent()
    if m == "dark":
        c = dict(bg="rgba(30, 33, 52, 0.66)", fg="#ffffff", dim="rgba(255,255,255,0.58)",
                 line="rgba(255,255,255,0.10)", hover="rgba(255,255,255,0.09)",
                 chip="rgba(255,255,255,0.10)", chip_on="#ffffff", chip_on_fg="#1c1c28",
                 field="rgba(255,255,255,0.07)", border="rgba(255,255,255,0.14)",
                 shadow="rgba(0,0,0,0.45)", btn="rgba(30, 33, 52, 0.70)")
    else:
        c = dict(bg="rgba(247, 248, 252, 0.78)", fg="#1c1c28", dim="rgba(28,28,40,0.58)",
                 line="rgba(0,0,0,0.10)", hover="rgba(0,0,0,0.07)",
                 chip="rgba(0,0,0,0.07)", chip_on="#1c1c28", chip_on_fg="#ffffff",
                 field="rgba(0,0,0,0.05)", border="rgba(0,0,0,0.12)",
                 shadow="rgba(0,0,0,0.25)", btn="rgba(247, 248, 252, 0.80)")
    return """
window.arcos-glass { background: transparent; }
.card { background: %(bg)s; color: %(fg)s; border: 1px solid %(border)s;
        box-shadow: 0 10px 34px %(shadow)s; font-family: "Inter", sans-serif; }
.card.pill { border-radius: 999px; padding: 4px 18px; }
.card.panel { border-radius: 26px; padding: 12px 14px 10px 14px; }
.card.menu { border-radius: 16px; padding: 6px; }
.card label { color: %(fg)s; }
.roundbtn { background: %(btn)s; color: %(fg)s; border: 1px solid %(border)s; border-radius: 999px;
            min-width: 44px; min-height: 44px; padding: 0; box-shadow: 0 6px 20px %(shadow)s; }
.roundbtn:hover { background: %(hover)s; }
entry.search-entry { background: transparent; border: none; box-shadow: none; outline: none;
                     color: %(fg)s; font-size: 17px; min-height: 38px; caret-color: %(accent)s; }
entry.search-entry > text > placeholder { color: %(dim)s; }
.ghost { background: %(field)s; color: %(dim)s; border-radius: 999px; padding: 4px 14px; font-size: 14px; }
.menubtn { background: transparent; border: none; box-shadow: none; padding: 4px; min-width: 28px; min-height: 28px; }
.menubtn:hover { background: %(hover)s; border-radius: 999px; }
.sep { background: %(line)s; min-height: 1px; margin: 6px 4px 4px 4px; }
.section { color: %(dim)s; font-size: 12px; font-weight: 600; padding: 10px 12px 4px 12px; }
list.results { background: transparent; }
list.results row { background: transparent; border-radius: 12px; padding: 7px 10px; margin: 1px 0; }
list.results row:hover { background: %(hover)s; }
list.results row:selected { background: alpha(%(accent)s, 0.55); color: #ffffff; }
list.results row:selected label { color: #ffffff; }
.title { font-size: 14px; font-weight: 500; }
.subtitle { font-size: 11px; color: %(dim)s; }
.hint { font-size: 11px; color: %(dim)s; }
.chip { background: %(chip)s; color: %(fg)s; border: none; border-radius: 999px; padding: 4px 14px;
        min-height: 0; box-shadow: none; font-size: 13px; }
.chip:checked { background: %(chip_on)s; color: %(chip_on_fg)s; }
flowboxchild { border-radius: 12px; padding: 2px; }
flowboxchild:hover { background: %(hover)s; }
flowboxchild button.appbtn { background: transparent; border: none; box-shadow: none; padding: 6px 4px; }
.appname { font-size: 12px; }
.empty { color: %(dim)s; font-size: 13px; padding: 28px 12px; }
.menuitem { background: transparent; border: none; box-shadow: none; border-radius: 8px;
            padding: 5px 12px; min-height: 0; color: %(fg)s; }
.menuitem:hover { background: %(accent)s; color: #ffffff; }
.menuitem:hover label { color: #ffffff; }
.menuitem .shortcut { color: %(dim)s; font-size: 12px; }
.menuitem:hover .shortcut { color: rgba(255,255,255,0.85); }
.confirm { padding: 10px 14px; }
button.danger { background: #e62d42; color: #ffffff; border: none; border-radius: 8px; }
popover > contents { background: %(bg)s; border-radius: 14px; border: 1px solid %(border)s; }
""" % dict(c, accent=a)


def load_css(Gtk, Gdk, extra=""):
    provider = Gtk.CssProvider()
    css = glass_css() + extra
    if hasattr(provider, "load_from_string"):
        provider.load_from_string(css)
    else:
        provider.load_from_data(css.encode("utf-8"))
    Gtk.StyleContext.add_provider_for_display(
        Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)
