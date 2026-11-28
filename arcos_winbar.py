#!/usr/bin/env python3
"""arcos-winbar - close / minimise / maximise buttons for the window you are using.

   arcos-winbar                 run the buttons (started automatically at login)
   arcos-winbar --close         do one action right now (used by keyboard shortcuts)
   arcos-winbar --minimize
   arcos-winbar --maximize
   arcos-winbar --restore       bring back minimised windows

Hyprland draws no title bars, so a small pill with the three round buttons floats
just above the active window (or inside its corner when the window is at the top of the screen).
"""
import json
import os
import subprocess
import sys

# ---- actions: Hyprland 0.55+ Lua first, the older command as a backup --------------------------------
LUA = {
    "close": 'hl.dispatch(hl.dsp.window.close())',
    "maximize": 'hl.dispatch(hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" }))',
    "minimize": ('local w = hl.get_active_window(); if w then '
                 'hl.dispatch(hl.dsp.window.tag({ tag = "minimized", window = w })); '
                 'hl.dispatch(hl.dsp.window.move({ workspace = "special:minimized", follow = false })) end'),
    "restore": ('hl.dispatch(hl.dsp.window.move({ workspace = hl.get_active_workspace(), window = "tag:minimized" })); '
                'hl.dispatch(hl.dsp.window.clear_tags({ window = "tag:minimized" }))'),
}
LEGACY = {"close": "killactive", "maximize": "fullscreen 1",
          "minimize": "movetoworkspacesilent special:minimized", "restore": None}


def run(cmd, timeout=3):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except (OSError, subprocess.SubprocessError) as e:
        return 1, str(e)


def act(name):
    rc, out = run(["hyprctl", "eval", LUA[name]])
    bad = rc != 0 or any(w in out.lower() for w in ("error", "unknown", "invalid"))
    if bad and LEGACY.get(name):
        run(["hyprctl", "dispatch", LEGACY[name]])


def hypr_json(args):
    rc, out = run(["hyprctl"] + args + ["-j"])
    if rc != 0:
        return None
    try:
        return json.loads(out)
    except ValueError:
        return None


def main_cli():
    for flag, name in (("--close", "close"), ("--minimize", "minimize"),
                       ("--maximize", "maximize"), ("--restore", "restore")):
        if flag in sys.argv:
            act(name)
            return True
    return False


if __name__ == "__main__" and main_cli():
    sys.exit(0)

# ---- the floating buttons ----------------------------------------------------------------------------
sys.path.insert(0, "/usr/local/lib/arcos")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gi  # noqa: E402

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Gtk4LayerShell", "1.0")
from gi.repository import Gdk, GLib, Gio, Gtk  # noqa: E402
from gi.repository import Gtk4LayerShell as LS  # noqa: E402

import arcos_common as C  # noqa: E402

BAR_CLEARANCE = 44      # the menu bar covers about this much at the top of the screen
PILL_W, PILL_H = 84, 28


def css():
    dark = C.mode() == "dark"
    bg = "rgba(30, 32, 50, 0.66)" if dark else "rgba(250, 250, 255, 0.78)"
    line = "rgba(255,255,255,0.18)" if dark else "rgba(0,0,0,0.14)"
    fg = "#ffffff" if dark else "#1c1c28"
    return """
window.arcwin { background: transparent; }
.pill { background: %(bg)s; border: 1px solid %(line)s; border-radius: 999px; padding: 6px 12px;
        box-shadow: 0 4px 14px rgba(0,0,0,0.32); }
.tl { min-width: 14px; min-height: 14px; padding: 0; border-radius: 999px; box-shadow: none;
      border: 1px solid rgba(0,0,0,0.25); }
.tl.close { background: #ff5f57; }
.tl.min { background: #febc2e; }
.tl.max { background: #28c840; }
.tl label { font-size: 10px; font-weight: 800; color: rgba(0,0,0,0.62); opacity: 0; }
.pill:hover .tl label { opacity: 1; }
.restore { background: %(bg)s; border: 1px solid %(line)s; border-radius: 999px; padding: 6px 14px;
           color: %(fg)s; font-size: 12px; box-shadow: 0 4px 14px rgba(0,0,0,0.32); }
""" % dict(bg=bg, line=line, fg=fg)


class FloatingWindow(Gtk.Window):
    def __init__(self, app, anchors):
        super().__init__(application=app)
        self.set_decorated(False)
        self.add_css_class("arcwin")
        self.set_focusable(False)
        LS.init_for_window(self)
        LS.set_namespace(self, "arcwin")
        LS.set_layer(self, LS.Layer.TOP)
        LS.set_keyboard_mode(self, LS.KeyboardMode.NONE)
        for edge in anchors:
            LS.set_anchor(self, edge, True)
        self.last = None

    def place(self, edge_a, a, edge_b, b):
        if self.last != (a, b):
            LS.set_margin(self, edge_a, int(a))
            LS.set_margin(self, edge_b, int(b))
            self.last = (a, b)


class Controls(FloatingWindow):
    def __init__(self, app):
        super().__init__(app, (LS.Edge.TOP, LS.Edge.LEFT))
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=9)
        box.add_css_class("pill")
        for cls, glyph, action in (("close", "\u00d7", "close"), ("min", "\u2013", "minimize"),
                                   ("max", "+", "maximize")):
            b = Gtk.Button()
            b.add_css_class("tl")
            b.add_css_class(cls)
            b.set_focusable(False)
            b.set_focus_on_click(False)
            b.set_child(Gtk.Label(label=glyph))
            b.connect("clicked", lambda _b, a=action: act(a))
            box.append(b)
        self.set_child(box)

    def move_to(self, x, y):
        self.place(LS.Edge.TOP, y, LS.Edge.LEFT, x)


class RestorePill(FloatingWindow):
    def __init__(self, app):
        super().__init__(app, (LS.Edge.BOTTOM, LS.Edge.RIGHT))
        self.btn = Gtk.Button()
        self.btn.add_css_class("restore")
        self.btn.set_focusable(False)
        self.btn.connect("clicked", lambda _b: act("restore"))
        self.set_child(self.btn)
        self.place(LS.Edge.BOTTOM, 120, LS.Edge.RIGHT, 18)

    def set_count(self, n):
        self.btn.set_label("\u25b4  %d minimised  \u2013  show" % n)


class WinBar(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="org.arcos.winbar", flags=Gio.ApplicationFlags.FLAGS_NONE)
        self.ticks = 0
        self.mons = {}

    def do_activate(self):
        self.hold()
        provider = Gtk.CssProvider()
        text = css()
        if hasattr(provider, "load_from_string"):
            provider.load_from_string(text)
        else:
            provider.load_from_data(text.encode())
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_USER)
        self.controls = Controls(self)
        self.restore = RestorePill(self)
        GLib.timeout_add(120, self.tick)

    def tick(self):
        self.ticks += 1
        if self.ticks % 8 == 1:
            self.refresh_slow()
        try:
            self.update_controls()
        except Exception:  # noqa: BLE001 - never let a hiccup stop the buttons
            self.controls.set_visible(False)
        return True

    def refresh_slow(self):
        mons = hypr_json(["monitors"]) or []
        self.mons = {m.get("id"): m for m in mons}
        clients = hypr_json(["clients"]) or []
        n = sum(1 for c in clients if str((c.get("workspace") or {}).get("name", "")) == "special:minimized")
        if n:
            self.restore.set_count(n)
        self.restore.set_visible(n > 0)

    def update_controls(self):
        w = hypr_json(["activewindow"])
        if not isinstance(w, dict) or not w.get("address") or w.get("hidden") or not w.get("mapped", True):
            self.controls.set_visible(False)
            return
        ws = str((w.get("workspace") or {}).get("name", ""))
        fs = w.get("fullscreen", 0)
        if ws.startswith("special") or fs in (2, True):
            self.controls.set_visible(False)
            return
        at, size = w.get("at") or [0, 0], w.get("size") or [0, 0]
        mon = self.mons.get(w.get("monitor"), {})
        x = at[0] - int(mon.get("x", 0))
        y = at[1] - int(mon.get("y", 0))
        if y - PILL_H - 6 >= BAR_CLEARANCE:
            self.controls.move_to(x + 6, y - PILL_H - 6)      # above the window
        else:
            self.controls.move_to(x + 10, y + 10)             # inside the corner
        self.controls.set_visible(True)


if __name__ == "__main__":
    sys.exit(WinBar().run([sys.argv[0]]))
