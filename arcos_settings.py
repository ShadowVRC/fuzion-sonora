#!/usr/bin/env python3
"""ArcOS Sonora Settings - the control center for the system.

   arcos-settings                    open Settings
   arcos-settings --page about       open a specific page
   (pages: network bluetooth display sound power appearance effects shell input shortcuts access
    defaults startup lock datetime language services windows about)
"""
import array
import json
import math
import os
import re
import shutil
import subprocess
import sys
import threading
import traceback

sys.path.insert(0, "/usr/local/lib/arcos")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gi  # noqa: E402

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk, Pango  # noqa: E402

import arcos_common as C  # noqa: E402
import arcos_ui as U  # noqa: E402


# ============================================================================ helpers
def sh(cmd, timeout=8, stdin=None):
    """Run a command. Returns (exit code, output). Never raises."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, input=stdin)
        return p.returncode, ((p.stdout or "") + (p.stderr or "")).strip()
    except FileNotFoundError:
        return 127, "%s is not installed" % cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "timed out"
    except OSError as e:
        return 1, str(e)


def have(cmd):
    return shutil.which(cmd) is not None


def bg(fn, done=None):
    """Run fn in a thread, then call done(result) on the main thread."""
    def work():
        try:
            res = fn()
        except Exception as e:  # noqa: BLE001
            res = e
        if done:
            GLib.idle_add(lambda: (done(res), False)[1])
    threading.Thread(target=work, daemon=True).start()


def spawn(cmd):
    try:
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         stdin=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass


def log_error():
    try:
        os.makedirs(C.CACHE, exist_ok=True)
        with open(os.path.join(C.CACHE, "settings.log"), "a", encoding="utf-8") as f:
            f.write(traceback.format_exc() + "\n")
    except OSError:
        pass


class Debounce:
    def __init__(self, fn, ms=350):
        self.fn, self.ms, self.src, self.args = fn, ms, None, ()

    def __call__(self, *args):
        self.args = args
        if self.src:
            GLib.source_remove(self.src)
        self.src = GLib.timeout_add(self.ms, self._fire)

    def _fire(self):
        self.src = None
        self.fn(*self.args)
        return False


def split_nm(line):
    """Split a nmcli terse line on ':' (a backslash escapes a colon)."""
    return [p.replace("\\:", ":").replace("\\\\", "\\") for p in re.split(r"(?<!\\):", line)]


def fmt_time(seconds):
    seconds = int(seconds)
    h, m = divmod(seconds // 60, 60)
    return "%d h %d min" % (h, m) if h else "%d min" % m


# ---- widget helpers
def make_group(title=None, desc=None):
    g = Adw.PreferencesGroup()
    if title:
        g.set_title(title)
    if desc:
        g.set_description(desc)
    return g


def action_row(title, subtitle=None):
    r = Adw.ActionRow()
    r.set_title(GLib.markup_escape_text(title))
    if subtitle:
        r.set_subtitle(GLib.markup_escape_text(subtitle))
    return r


def small_button(label, cb, css=None):
    b = Gtk.Button(label=label)
    b.set_valign(Gtk.Align.CENTER)
    if css:
        b.add_css_class(css)
    b.connect("clicked", lambda _b: cb())
    return b


def switch_row(title, subtitle, active, cb):
    r = Adw.SwitchRow()
    r.set_title(GLib.markup_escape_text(title))
    if subtitle:
        r.set_subtitle(GLib.markup_escape_text(subtitle))
    r.set_active(bool(active))
    r.connect("notify::active", lambda row, _p: cb(row.get_active()))
    return r


def combo_row(title, items, selected, cb, subtitle=None, search=False):
    r = Adw.ComboRow()
    r.set_title(GLib.markup_escape_text(title))
    if subtitle:
        r.set_subtitle(GLib.markup_escape_text(subtitle))
    r.set_model(Gtk.StringList.new(list(items)))
    r.set_selected(max(0, min(selected, len(items) - 1)) if items else 0)
    if search:
        try:
            r.set_expression(Gtk.PropertyExpression.new(Gtk.StringObject, None, "string"))
        except Exception:  # noqa: BLE001
            pass
        r.set_enable_search(True)
    r.connect("notify::selected", lambda row, _p: cb(row.get_selected()))
    return r


def scale_row(title, lo, hi, step, value, cb, subtitle=None, width=260):
    r = action_row(title, subtitle)
    s = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, lo, hi, step)
    s.set_size_request(width, -1)
    s.set_valign(Gtk.Align.CENTER)
    s.set_draw_value(False)
    s.set_value(value)
    s.connect("value-changed", lambda sc: cb(sc.get_value()))
    r.add_suffix(s)
    r.scale = s
    return r


def clear_group(group, rows):
    for r in rows:
        group.remove(r)
    rows.clear()


class Page:
    """One page of the Settings window."""
    name = "page"
    title = "Page"
    icon = "preferences-system-symbolic"

    def __init__(self, win):
        self.win = win
        self.busy = False                     # true while we update widgets (ignore their signals)
        self.widget = Adw.PreferencesPage()
        self.build()

    def build(self):
        pass

    def refresh(self):
        pass

    def on_show(self):
        self.refresh()

    def on_hide(self):
        pass

    def status(self, title, desc, icon="dialog-warning-symbolic"):
        sp = Adw.StatusPage()
        sp.set_title(title)
        sp.set_description(desc)
        sp.set_icon_name(icon)
        g = Adw.PreferencesGroup()
        g.add(sp)
        self.widget.add(g)
        return g


# ============================================================================ Network
class NetworkPage(Page):
    name, title, icon = "network", "Network", "network-wireless-symbolic"

    def build(self):
        self.rows = {"wifi": [], "saved": [], "eth": []}
        self.wifi_switch = switch_row("Wi-Fi", None, False, self.on_wifi_toggle)
        g = make_group()
        g.add(self.wifi_switch)
        self.widget.add(g)
        self.nets = make_group("Available networks")
        self.nets.set_header_suffix(small_button("Scan", self.scan))
        self.widget.add(self.nets)
        self.saved = make_group("Saved connections")
        self.widget.add(self.saved)
        self.eth = make_group("Ethernet")
        self.widget.add(self.eth)

    def on_wifi_toggle(self, on):
        if not self.busy:
            sh(["nmcli", "radio", "wifi", "on" if on else "off"])
            GLib.timeout_add(1200, lambda: (self.refresh(), False)[1])

    def scan(self):
        bg(lambda: sh(["nmcli", "dev", "wifi", "rescan"], 10), lambda _r: self.refresh())

    def gather(self):
        if not have("nmcli"):
            return {"error": "NetworkManager (nmcli) is not installed."}
        rc, out = sh(["nmcli", "-t", "-f", "WIFI", "radio"])
        if rc != 0:
            return {"error": "NetworkManager is not running."}
        d = {"wifi_on": out.strip() == "enabled", "nets": [], "saved": [], "eth": []}
        rc, out = sh(["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "dev", "wifi", "list", "--rescan", "no"])
        seen = set()
        for line in out.splitlines() if rc == 0 else []:
            p = split_nm(line)
            if len(p) >= 4 and p[1] and p[1] not in seen:
                seen.add(p[1])
                d["nets"].append({"active": p[0] == "*", "ssid": p[1], "signal": int(p[2] or 0), "sec": p[3]})
        rc, out = sh(["nmcli", "-t", "-f", "NAME,TYPE,ACTIVE", "connection", "show"])
        for line in out.splitlines() if rc == 0 else []:
            p = split_nm(line)
            if len(p) >= 3:
                d["saved"].append({"name": p[0], "type": p[1], "active": p[2] == "yes"})
        rc, out = sh(["nmcli", "-t", "-f", "GENERAL.DEVICE,GENERAL.TYPE,GENERAL.HWADDR,GENERAL.STATE,"
                      "IP4.ADDRESS,IP4.GATEWAY,IP4.DNS,IP6.ADDRESS", "dev", "show"])
        cur = None
        for line in out.splitlines() if rc == 0 else []:
            if ":" not in line:
                continue
            key, val = line.split(":", 1)
            key = re.sub(r"\[\d+\]$", "", key)
            if key == "GENERAL.DEVICE":
                cur = {"dev": val, "lists": {}}
                d["eth"].append(cur)
            elif cur is not None:
                cur["lists"].setdefault(key, []).append(val.replace("\\:", ":"))
        d["eth"] = [e for e in d["eth"] if e["lists"].get("GENERAL.TYPE", [""])[0] == "ethernet"]
        return d

    def refresh(self):
        bg(self.gather, self.show)

    def show(self, d):
        if isinstance(d, Exception):
            return
        for g in (self.nets, self.saved, self.eth):
            g.set_visible("error" not in d)
        if "error" in d:
            if not getattr(self, "err_shown", False):
                self.err_shown = True
                self.status("Network unavailable", d["error"])
            return
        self.busy = True
        self.wifi_switch.set_active(d["wifi_on"])
        self.busy = False
        clear_group(self.nets, self.rows["wifi"])
        for n in sorted(d["nets"], key=lambda x: (not x["active"], -x["signal"])):
            sec = "Open" if n["sec"] in ("", "--") else n["sec"]
            r = action_row(n["ssid"], "%s \u00b7 signal %d%%%s" % (sec, n["signal"], " \u00b7 Connected" if n["active"] else ""))
            if n["active"]:
                r.add_suffix(small_button("Disconnect", lambda s=n["ssid"]: self.disconnect(s)))
            else:
                r.add_suffix(small_button("Connect", lambda nn=n: self.connect(nn), "suggested-action"))
            self.nets.add(r)
            self.rows["wifi"].append(r)
        if not d["nets"]:
            r = action_row("No networks found" if d["wifi_on"] else "Wi-Fi is off")
            self.nets.add(r)
            self.rows["wifi"].append(r)
        clear_group(self.saved, self.rows["saved"])
        for c in d["saved"]:
            if c["type"] in ("loopback", "bridge", "tun"):
                continue
            r = action_row(c["name"], c["type"].replace("802-11-wireless", "Wi-Fi").replace("802-3-ethernet", "Ethernet")
                           + (" \u00b7 Active" if c["active"] else ""))
            r.add_suffix(small_button("Forget", lambda nm=c["name"]: self.forget(nm), "destructive-action"))
            self.saved.add(r)
            self.rows["saved"].append(r)
        clear_group(self.eth, self.rows["eth"])
        for e in d["eth"]:
            L = e["lists"]
            get = lambda k: ", ".join(L.get(k, [])) or "\u2014"  # noqa: E731
            r = action_row("Ethernet (%s)" % e["dev"], get("GENERAL.STATE"))
            self.eth.add(r)
            self.rows["eth"].append(r)
            for label, key in (("IPv4 address", "IP4.ADDRESS"), ("Gateway", "IP4.GATEWAY"), ("DNS", "IP4.DNS"),
                               ("IPv6 address", "IP6.ADDRESS"), ("MAC address", "GENERAL.HWADDR")):
                rr = action_row(label, get(key))
                rr.set_subtitle_selectable(True)
                self.eth.add(rr)
                self.rows["eth"].append(rr)
        if not d["eth"]:
            r = action_row("No Ethernet adapter found")
            self.eth.add(r)
            self.rows["eth"].append(r)

    def connect(self, n):
        saved = [c["name"] for c in getattr(self, "last_saved", [])]
        if n["sec"] in ("", "--"):
            self.run_connect(["nmcli", "dev", "wifi", "connect", n["ssid"]], n["ssid"])
            return
        self.win.ask_text("Connect to %s" % n["ssid"], "Enter the Wi-Fi password.", "Password", True, "Connect",
                          lambda pw: self.run_connect(["nmcli", "dev", "wifi", "connect", n["ssid"], "password", pw], n["ssid"]))

    def run_connect(self, cmd, ssid):
        self.win.toast("Connecting to %s..." % ssid)

        def done(res):
            rc, out = res
            self.win.toast("Connected to %s" % ssid if rc == 0 else "Could not connect: %s" % out[:120])
            self.refresh()
        bg(lambda: sh(cmd, 30), done)

    def disconnect(self, ssid):
        bg(lambda: sh(["nmcli", "connection", "down", "id", ssid]), lambda _r: self.refresh())

    def forget(self, name):
        self.win.confirm("Forget %s?" % name, "The saved settings and password will be removed.", "Forget",
                         lambda: bg(lambda: sh(["nmcli", "connection", "delete", "id", name]), lambda _r: self.refresh()))


# ============================================================================ Bluetooth
class BluetoothPage(Page):
    name, title, icon = "bluetooth", "Bluetooth", "bluetooth-symbolic"

    def build(self):
        self.rows = []
        self.power = switch_row("Bluetooth", None, False, self.on_power)
        g = make_group()
        g.add(self.power)
        self.widget.add(g)
        self.devs = make_group("Devices")
        self.devs.set_header_suffix(small_button("Scan", self.scan))
        self.widget.add(self.devs)

    def on_power(self, on):
        if not self.busy:
            bg(lambda: sh(["bluetoothctl", "power", "on" if on else "off"]), lambda _r: self.refresh())

    def scan(self):
        self.win.toast("Scanning for devices...")
        bg(lambda: sh(["bluetoothctl", "--timeout", "8", "scan", "on"], 14), lambda _r: self.refresh())

    def gather(self):
        if not have("bluetoothctl"):
            return {"error": "BlueZ (bluetoothctl) is not installed."}
        rc, out = sh(["bluetoothctl", "show"])
        if rc != 0 or "Powered:" not in out:
            return {"error": "No Bluetooth adapter was found."}
        d = {"on": "Powered: yes" in out, "devices": []}
        rc, out = sh(["bluetoothctl", "devices"])
        for line in out.splitlines():
            m = re.match(r"Device ([0-9A-F:]{17}) (.*)", line)
            if not m:
                continue
            mac, name = m.groups()
            _rc, info = sh(["bluetoothctl", "info", mac])
            bat = re.search(r"Battery Percentage: .*\((\d+)\)", info)
            d["devices"].append({"mac": mac, "name": name, "paired": "Paired: yes" in info,
                                 "trusted": "Trusted: yes" in info, "connected": "Connected: yes" in info,
                                 "battery": int(bat.group(1)) if bat else None})
        return d

    def refresh(self):
        bg(self.gather, self.show)

    def show(self, d):
        if isinstance(d, Exception):
            return
        self.devs.set_visible("error" not in d)
        if "error" in d:
            if not getattr(self, "err_shown", False):
                self.err_shown = True
                self.status("Bluetooth unavailable", d["error"], "bluetooth-disabled-symbolic")
            return
        self.busy = True
        self.power.set_active(d["on"])
        self.busy = False
        clear_group(self.devs, self.rows)
        for dev in sorted(d["devices"], key=lambda x: (not x["connected"], not x["paired"], x["name"])):
            bits = ["Connected" if dev["connected"] else ("Paired" if dev["paired"] else "Not paired")]
            if dev["battery"] is not None:
                bits.append("Battery %d%%" % dev["battery"])
            r = action_row(dev["name"], " \u00b7 ".join(bits))
            mac = dev["mac"]
            if not dev["paired"]:
                r.add_suffix(small_button("Pair", lambda m=mac: self.pair(m), "suggested-action"))
            elif dev["connected"]:
                r.add_suffix(small_button("Disconnect", lambda m=mac: self.cmd(["disconnect", m])))
            else:
                r.add_suffix(small_button("Connect", lambda m=mac: self.cmd(["connect", m]), "suggested-action"))
            if dev["paired"] and not dev["trusted"]:
                r.add_suffix(small_button("Trust", lambda m=mac: self.cmd(["trust", m])))
            r.add_suffix(small_button("Remove", lambda m=mac: self.cmd(["remove", m]), "destructive-action"))
            self.devs.add(r)
            self.rows.append(r)
        if not d["devices"]:
            r = action_row("No devices yet", "Turn on pairing mode on your device, then press Scan.")
            self.devs.add(r)
            self.rows.append(r)

    def cmd(self, args):
        bg(lambda: sh(["bluetoothctl"] + args, 20), lambda _r: self.refresh())

    def pair(self, mac):
        self.win.toast("Pairing...")

        def work():
            sh(["bluetoothctl", "pair", mac], 30)
            sh(["bluetoothctl", "trust", mac])
            return sh(["bluetoothctl", "connect", mac], 20)
        bg(work, lambda _r: self.refresh())


# ============================================================================ Display
class DisplayPage(Page):
    name, title, icon = "display", "Displays", "video-display-symbolic"
    SCALES = ["Auto", "100%", "125%", "150%", "175%", "200%", "250%", "300%"]
    SCALE_VALUES = ["auto", "1", "1.25", "1.5", "1.75", "2", "2.5", "3"]
    ORIENT = ["Landscape", "Portrait (right)", "Upside down", "Portrait (left)"]

    def build(self):
        cfg = U.load()
        g = make_group("Interface size", "Sizes follow your screen automatically. Change them here if you prefer bigger or smaller. "
                       "The top bar and Dock sizes are in ArcOS Shell settings.")
        cur = str(cfg.get("scale", "auto"))
        g.add(combo_row("Scale", self.SCALES, self.SCALE_VALUES.index(cur) if cur in self.SCALE_VALUES else 0,
                        lambda i: U.set_value("scale", self.SCALE_VALUES[i]), "Scales everything on every screen"))
        self.widget.add(g)
        self.mon_groups = []
        self.night = make_group("Night Light", "Warmer colors in the evening.")
        nl = cfg.get("night_light", {})
        self.night.add(switch_row("Night Light", None if have("hyprsunset") else "hyprsunset is not installed",
                                  nl.get("enabled"), lambda on: U.set_value("night_light.enabled", bool(on))))
        self.temp_apply = Debounce(lambda v: U.set_value("night_light.temperature", int(v)))
        self.night.add(scale_row("Color temperature", 2500, 6500, 100, nl.get("temperature", 4500),
                                 lambda v: self.temp_apply(v), "Lower is warmer"))
        self.widget.add(self.night)
        self.built_monitors = False

    def refresh(self):
        if self.built_monitors:
            return
        mons = U.monitors()
        if not mons:
            self.status("Display settings unavailable", "Screens can only be changed inside the ArcOS Sonora desktop.",
                        "video-display-symbolic")
            self.built_monitors = True
            return
        self.built_monitors = True
        cfg = U.load()
        for m in mons:
            self.add_monitor(m, cfg)

    def add_monitor(self, m, cfg):
        name = m.get("name", "?")
        own = cfg.get("monitors", {}).get(name, {})
        g = make_group("%s \u00b7 %s" % (name, (m.get("description") or "Display")[:48]),
                       "%dx%d at %.0f Hz, scale %s" % (m.get("width", 0), m.get("height", 0),
                                                         m.get("refreshRate", 0), m.get("scale", 1)))
        modes = {}
        for s in m.get("availableModes", []):
            mm = re.match(r"(\d+x\d+)@([\d.]+)Hz", s)
            if mm:
                modes.setdefault(mm.group(1), []).append(mm.group(2))
        res_list = sorted(modes, key=lambda r: -int(r.split("x")[0]) * int(r.split("x")[1]))
        cur_res = "%dx%d" % (m.get("width", 0), m.get("height", 0))
        state = {"res": cur_res if cur_res in modes else (res_list[0] if res_list else ""),
                 "rate": "%.2f" % m.get("refreshRate", 60), "scale": str(own.get("scale", "")) or "",
                 "transform": int(own.get("transform", m.get("transform", 0)))}
        rate_row = [None]

        def rates_for(res):
            return sorted(set(modes.get(res, [])), key=lambda x: -float(x))

        def set_res(i):
            state["res"] = res_list[i]
            rl = rates_for(state["res"])
            rate_row[0].set_model(Gtk.StringList.new(["%s Hz" % r for r in rl]))
            state["rate"] = rl[0] if rl else state["rate"]

        if res_list:
            g.add(combo_row("Resolution", res_list, res_list.index(state["res"]) if state["res"] in res_list else 0, set_res))
            rl = rates_for(state["res"])
            rr = combo_row("Refresh rate", ["%s Hz" % r for r in rl],
                           min(range(len(rl)), key=lambda i: abs(float(rl[i]) - float(state["rate"]))) if rl else 0,
                           lambda i: state.__setitem__("rate", rates_for(state["res"])[i]))
            rate_row[0] = rr
            g.add(rr)
        scale_opts = ["Same as interface scale"] + self.SCALES[1:]
        cur_i = 0
        if state["scale"] in self.SCALE_VALUES[1:]:
            cur_i = self.SCALE_VALUES[1:].index(state["scale"]) + 1
        g.add(combo_row("Scale for this screen", scale_opts, cur_i,
                        lambda i: state.__setitem__("scale", "" if i == 0 else self.SCALE_VALUES[i])))
        g.add(combo_row("Orientation", self.ORIENT, state["transform"] % 4,
                        lambda i: state.__setitem__("transform", i)))

        def apply():
            entry = {"mode": "%s@%s" % (state["res"], state["rate"]) if state["res"] else "preferred",
                     "transform": state["transform"]}
            if state["scale"]:
                entry["scale"] = state["scale"]
            U.set_value("monitors.%s" % name, entry)
            self.win.toast("Display settings applied")
        row = action_row("Apply", "Changes take effect immediately.")
        row.add_suffix(small_button("Apply", apply, "suggested-action"))
        g.add(row)
        self.widget.remove(self.night)
        self.widget.add(g)
        self.widget.add(self.night)


# ============================================================================ Sound
class SoundPage(Page):
    name, title, icon = "sound", "Sound", "audio-volume-high-symbolic"

    def build(self):
        self.sink_names, self.src_names, self.app_rows = [], [], {}
        self.meter_stop = threading.Event()
        self.meter_proc = None
        self.out = make_group("Output")
        self.out_combo = combo_row("Output device", [], 0, self.pick_sink)
        self.out.add(self.out_combo)
        self.out_vol = scale_row("Volume", 0, 100, 1, 50, self.set_sink_vol)
        self.out.add(self.out_vol)
        self.out_mute = switch_row("Mute", None, False, lambda on: self.run(["pactl", "set-sink-mute", "@DEFAULT_SINK@", "1" if on else "0"]))
        self.out.add(self.out_mute)
        self.widget.add(self.out)
        self.inp = make_group("Input")
        self.in_combo = combo_row("Input device", [], 0, self.pick_src)
        self.inp.add(self.in_combo)
        self.in_vol = scale_row("Volume", 0, 100, 1, 50, self.set_src_vol)
        self.inp.add(self.in_vol)
        self.in_mute = switch_row("Mute", None, False, lambda on: self.run(["pactl", "set-source-mute", "@DEFAULT_SOURCE@", "1" if on else "0"]))
        self.inp.add(self.in_mute)
        meter_row = action_row("Input level")
        self.meter = Gtk.LevelBar()
        self.meter.set_min_value(0)
        self.meter.set_max_value(1)
        self.meter.set_size_request(260, 10)
        self.meter.set_valign(Gtk.Align.CENTER)
        meter_row.add_suffix(self.meter)
        self.inp.add(meter_row)
        self.widget.add(self.inp)
        self.apps = make_group("Applications", "Volume for each app that is playing sound.")
        self.widget.add(self.apps)

    def run(self, cmd):
        if not self.busy:
            bg(lambda: sh(cmd), None)

    @staticmethod
    def pct(item):
        vols = item.get("volume") or {}
        for ch in vols.values():
            try:
                return int(str(ch.get("value_percent", "0%")).rstrip("%"))
            except (ValueError, AttributeError):
                continue
        return 0

    def gather(self):
        if not have("pactl"):
            return {"error": "PipeWire / PulseAudio tools (pactl) are not installed."}
        rc, out = sh(["pactl", "--format=json", "list", "sinks"])
        if rc != 0:
            return {"error": "The audio service is not running."}
        d = {"sinks": json.loads(out or "[]"), "default_sink": sh(["pactl", "get-default-sink"])[1],
             "default_src": sh(["pactl", "get-default-source"])[1]}
        rc, out = sh(["pactl", "--format=json", "list", "sources"])
        d["sources"] = [s for s in json.loads(out or "[]") if not s.get("name", "").endswith(".monitor")]
        rc, out = sh(["pactl", "--format=json", "list", "sink-inputs"])
        d["inputs"] = json.loads(out or "[]") if rc == 0 else []
        return d

    def refresh(self):
        bg(self.gather, self.show)

    def show(self, d):
        if isinstance(d, Exception):
            return
        for g in (self.out, self.inp, self.apps):
            g.set_visible("error" not in d)
        if "error" in d:
            if not getattr(self, "err_shown", False):
                self.err_shown = True
                self.status("Sound unavailable", d["error"], "audio-volume-muted-symbolic")
            return
        self.busy = True
        try:
            sinks, srcs = d["sinks"], d["sources"]
            names = [s["name"] for s in sinks]
            if names != self.sink_names:
                self.sink_names = names
                self.out_combo.set_model(Gtk.StringList.new([s.get("description", s["name"]) for s in sinks]))
            if d["default_sink"] in names:
                self.out_combo.set_selected(names.index(d["default_sink"]))
                cur = sinks[names.index(d["default_sink"])]
                if not self.out_vol.scale.has_focus():
                    self.out_vol.scale.set_value(self.pct(cur))
                self.out_mute.set_active(bool(cur.get("mute")))
            snames = [s["name"] for s in srcs]
            if snames != self.src_names:
                self.src_names = snames
                self.in_combo.set_model(Gtk.StringList.new([s.get("description", s["name"]) for s in srcs]))
            if d["default_src"] in snames:
                self.in_combo.set_selected(snames.index(d["default_src"]))
                cur = srcs[snames.index(d["default_src"])]
                if not self.in_vol.scale.has_focus():
                    self.in_vol.scale.set_value(self.pct(cur))
                self.in_mute.set_active(bool(cur.get("mute")))
            self.show_apps(d["inputs"])
        finally:
            self.busy = False
        self.start_meter(d["default_src"])

    def show_apps(self, inputs):
        ids = [i["index"] for i in inputs]
        if sorted(ids) != sorted(self.app_rows):
            clear_group(self.apps, list(self.app_rows.values()))
            self.app_rows = {}
            for i in inputs:
                props = i.get("properties", {})
                name = props.get("application.name") or props.get("media.name") or "Application"
                idx = i["index"]
                row = scale_row(name, 0, 100, 1, self.pct(i),
                                lambda v, n=idx: self.run(["pactl", "set-sink-input-volume", str(n), "%d%%" % int(v)]))
                self.apps.add(row)
                self.app_rows[idx] = row
            if not inputs:
                row = action_row("Nothing is playing sound")
                self.apps.add(row)
                self.app_rows[-1] = row
        else:
            for i in inputs:
                r = self.app_rows.get(i["index"])
                if r and not r.scale.has_focus():
                    r.scale.set_value(self.pct(i))

    def pick_sink(self, i):
        if not self.busy and 0 <= i < len(self.sink_names):
            self.run(["pactl", "set-default-sink", self.sink_names[i]])

    def pick_src(self, i):
        if not self.busy and 0 <= i < len(self.src_names):
            self.run(["pactl", "set-default-source", self.src_names[i]])

    def set_sink_vol(self, v):
        self.run(["pactl", "set-sink-volume", "@DEFAULT_SINK@", "%d%%" % int(v)])

    def set_src_vol(self, v):
        self.run(["pactl", "set-source-volume", "@DEFAULT_SOURCE@", "%d%%" % int(v)])

    # ---- live microphone level
    def start_meter(self, source):
        if self.meter_proc is not None or not have("parec") or not source:
            return
        self.meter_stop.clear()

        def work():
            try:
                proc = subprocess.Popen(["parec", "-d", source, "--format=s16le", "--rate=8000", "--channels=1",
                                         "--latency-msec=50"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            except OSError:
                return
            self.meter_proc = proc
            try:
                while not self.meter_stop.is_set():
                    chunk = proc.stdout.read(800)
                    if not chunk:
                        break
                    samples = array.array("h", chunk[:len(chunk) // 2 * 2])
                    if samples:
                        rms = math.sqrt(sum(s * s for s in samples) / len(samples))
                        level = min(1.0, rms / 9000.0)
                        GLib.idle_add(lambda lv=level: (self.meter.set_value(lv), False)[1])
            finally:
                proc.kill()
                self.meter_proc = None
        threading.Thread(target=work, daemon=True).start()

    def on_hide(self):
        self.meter_stop.set()
        if self.meter_proc is not None:
            try:
                self.meter_proc.kill()
            except OSError:
                pass


# ============================================================================ Power
class PowerPage(Page):
    name, title, icon = "power", "Power & Battery", "battery-symbolic"
    PROFILES = [("performance", "Performance"), ("balanced", "Balanced"), ("power-saver", "Power Saver")]
    TIMES = [("Never", 0), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300), ("10 minutes", 600),
             ("15 minutes", 900), ("30 minutes", 1800), ("1 hour", 3600)]

    def build(self):
        self.battery_rows = []
        self.bat = make_group("Battery")
        self.widget.add(self.bat)
        self.prof_group = make_group("Power mode")
        self.prof_combo = combo_row("Mode", [p[1] for p in self.PROFILES], 1, self.set_profile)
        self.prof_group.add(self.prof_combo)
        self.widget.add(self.prof_group)
        cfg = U.load()["power"]
        g = make_group("Screen and sleep")

        def idx(sec):
            for i, (_l, s) in enumerate(self.TIMES):
                if s == sec:
                    return i
            return 0
        for title, key in (("Turn off the screen after", "screen_off"), ("Lock the screen after", "lock"),
                           ("Suspend after", "suspend")):
            g.add(combo_row(title, [t[0] for t in self.TIMES], idx(cfg.get(key, 0)),
                            lambda i, k=key: U.set_value("power." + k, self.TIMES[i][1])))
        self.widget.add(g)

    def gather(self):
        d = {"battery": None, "profile": None, "profiles": []}
        if have("upower"):
            rc, out = sh(["upower", "-e"])
            for path in out.splitlines():
                if "battery" in path:
                    _rc, info = sh(["upower", "-i", path])
                    d["battery"] = info
                    break
        if have("powerprofilesctl"):
            rc, out = sh(["powerprofilesctl", "get"])
            if rc == 0:
                d["profile"] = out.strip()
                d["profiles"] = [m for m in re.findall(r"^\*?\s*([a-z\-]+):", sh(["powerprofilesctl", "list"])[1], re.M)]
        return d

    def refresh(self):
        bg(self.gather, self.show)

    def show(self, d):
        if isinstance(d, Exception):
            return
        clear_group(self.bat, self.battery_rows)
        info = d["battery"]
        if not info:
            r = action_row("No battery detected", "This looks like a desktop computer." if have("upower") else "UPower is not installed.")
            self.bat.add(r)
            self.battery_rows.append(r)
        else:
            def f(key):
                m = re.search(r"^\s*%s:\s*(.+)$" % re.escape(key), info, re.M)
                return m.group(1).strip() if m else None
            pct, state = f("percentage"), f("state")
            r = action_row("%s" % (pct or "?"), (state or "").capitalize())
            self.bat.add(r)
            self.battery_rows.append(r)
            rem = f("time to empty") or f("time to full")
            if rem:
                rr = action_row("Time remaining" if f("time to empty") else "Time until full", rem)
                self.bat.add(rr)
                self.battery_rows.append(rr)
            full, design = f("energy-full"), f("energy-full-design")
            cap = f("capacity")
            if cap or (full and design):
                rr = action_row("Battery health", cap or "%s of %s" % (full, design))
                self.bat.add(rr)
                self.battery_rows.append(rr)
        self.prof_group.set_visible(bool(d["profile"]))
        if d["profile"]:
            keys = [p[0] for p in self.PROFILES]
            self.busy = True
            if d["profile"] in keys:
                self.prof_combo.set_selected(keys.index(d["profile"]))
            self.busy = False

    def set_profile(self, i):
        if not self.busy:
            bg(lambda: sh(["powerprofilesctl", "set", self.PROFILES[i][0]]), None)


# ============================================================================ Appearance
class AppearancePage(Page):
    name, title, icon = "appearance", "Appearance", "applications-graphics-symbolic"

    def build(self):
        mode = C.mode()
        g = make_group("Style")
        row = action_row("Dark or light", "Also switches the wallpaper.")
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        box.add_css_class("linked")
        box.set_valign(Gtk.Align.CENTER)
        self.dark_btn = Gtk.ToggleButton(label="Dark")
        self.light_btn = Gtk.ToggleButton(label="Light")
        self.light_btn.set_group(self.dark_btn)
        (self.light_btn if mode == "light" else self.dark_btn).set_active(True)
        self.dark_btn.connect("toggled", lambda b: self.set_mode("dark") if b.get_active() else None)
        self.light_btn.connect("toggled", lambda b: self.set_mode("light") if b.get_active() else None)
        box.append(self.dark_btn)
        box.append(self.light_btn)
        row.add_suffix(box)
        g.add(row)
        # accent colors
        arow = action_row("Accent color")
        abox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        abox.set_valign(Gtk.Align.CENTER)
        css = ""
        self.accent_buttons = {}
        cur = U.load().get("accent", "blue")
        for name, hexcol in C.ACCENTS.items():
            b = Gtk.Button()
            b.add_css_class("accent-dot")
            b.add_css_class("accent-%s" % name)
            b.set_tooltip_text(name.capitalize())
            b.set_size_request(26, 26)
            b.connect("clicked", lambda _b, n=name: self.set_accent(n))
            abox.append(b)
            self.accent_buttons[name] = b
            css += ".accent-%s { background: %s; border-radius: 999px; min-width: 26px; min-height: 26px; padding: 0; }\n" % (name, hexcol)
        css += ".accent-dot.selected { border: 3px solid @window_fg_color; }\n"
        provider = Gtk.CssProvider()
        if hasattr(provider, "load_from_string"):
            provider.load_from_string(css)
        else:
            provider.load_from_data(css.encode())
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.mark_accent(cur)
        arow.add_suffix(abox)
        g.add(arow)
        # font
        frow = action_row("System font")
        self.font_btn = Gtk.FontDialogButton()
        self.font_btn.set_dialog(Gtk.FontDialog())
        self.font_btn.set_valign(Gtk.Align.CENTER)
        rc, out = sh(["gsettings", "get", "org.gnome.desktop.interface", "font-name"])
        name = out.strip().strip("'") if rc == 0 and out else "Inter 10"
        from gi.repository import Pango as _P
        self.font_btn.set_font_desc(_P.FontDescription.from_string(name))
        self.font_btn.connect("notify::font-desc", self.on_font)
        frow.add_suffix(self.font_btn)
        g.add(frow)
        self.widget.add(g)
        wg = make_group("Wallpaper", "ArcOS Sonora has two wallpapers: Sonora Light and Sonora Dark. They switch with the dark / light mode.")
        wr = action_row("Choose a different wallpaper", "Press Ctrl + Alt + W, or open ArcOS Shell settings.")
        wr.add_suffix(small_button("Open", lambda: spawn(["qs", "-c", "MacShell", "ipc", "call", "wallpapers", "toggle"])))
        wg.add(wr)
        self.widget.add(wg)

    def set_mode(self, mode):
        if C.mode() != mode:
            bg(lambda: sh(["arcos-theme", mode], 15), None)

    def set_accent(self, name):
        self.mark_accent(name)
        bg(lambda: U.set_value("accent", name), None)

    def mark_accent(self, name):
        for n, b in self.accent_buttons.items():
            (b.add_css_class if n == name else b.remove_css_class)("selected")

    def on_font(self, btn, _p):
        desc = btn.get_font_desc()
        if desc:
            font = desc.to_string()
            bg(lambda: sh(["gsettings", "set", "org.gnome.desktop.interface", "font-name", font]), None)



# ============================================================================ Input
class InputPage(Page):
    name, title, icon = "input", "Keyboard & Mouse", "input-keyboard-symbolic"
    COMMON = ["us", "gb", "de", "fr", "es", "it", "pt", "br", "ru", "pl", "se", "no", "dk", "fi", "tr", "jp",
              "kr", "cz", "ua", "nl", "ch", "ca", "latam", "il", "ar", "in"]

    def build(self):
        cfg = U.load()["input"]
        layouts = self.COMMON[:]
        if have("localectl"):
            rc, out = sh(["localectl", "list-x11-keymap-layouts"], 6)
            if rc == 0 and out:
                layouts = out.split()
        cur = cfg.get("kb_layout", "us")
        if cur not in layouts:
            layouts.insert(0, cur)
        kb = make_group("Keyboard")
        kb.add(combo_row("Layout", layouts, layouts.index(cur),
                         lambda i: U.set_value("input.kb_layout", layouts[i]), "Type to search", search=True))
        rate = Debounce(lambda v: U.set_value("input.repeat_rate", int(v)))
        delay = Debounce(lambda v: U.set_value("input.repeat_delay", int(v)))
        kb.add(scale_row("Key repeat speed", 5, 60, 1, cfg.get("repeat_rate", 25), lambda v: rate(v), "Characters per second"))
        kb.add(scale_row("Delay before repeat", 150, 1000, 10, cfg.get("repeat_delay", 600), lambda v: delay(v), "Milliseconds"))
        self.widget.add(kb)
        ms = make_group("Mouse")
        sens = Debounce(lambda v: U.set_value("input.sensitivity", round(v, 2)))
        ms.add(scale_row("Pointer speed", -1, 1, 0.05, cfg.get("sensitivity", 0.0), lambda v: sens(v)))
        ms.add(combo_row("Acceleration", ["Adaptive (default)", "Flat (no acceleration)"],
                         1 if cfg.get("accel_profile") == "flat" else 0,
                         lambda i: U.set_value("input.accel_profile", "flat" if i else "adaptive")))
        ms.add(switch_row("Natural scrolling", "Content moves with your finger or wheel direction.",
                          cfg.get("natural_scroll"), lambda on: U.set_value("input.natural_scroll", bool(on))))
        self.widget.add(ms)
        tp = make_group("Touchpad")
        tp.add(switch_row("Natural scrolling", None, cfg.get("touchpad_natural_scroll", True),
                          lambda on: U.set_value("input.touchpad_natural_scroll", bool(on))))
        tp.add(switch_row("Tap to click", None, cfg.get("tap_to_click", True),
                          lambda on: U.set_value("input.tap_to_click", bool(on))))
        self.widget.add(tp)


# ============================================================================ Windows apps
class WindowsPage(Page):
    name, title, icon = "windows", "Windows Apps & Games", "applications-games-symbolic"
    ROOT = os.path.join(C.HOME, ".local", "share", "fuzion")

    def build(self):
        self.rows = []
        self.tmpl = make_group("Windows support", "Shared parts every Windows program uses.")
        self.widget.add(self.tmpl)
        opts = make_group("Options")
        opts.add(switch_row("Use GameMode for Windows programs", "Gives games a speed boost while they run.",
                            has_flag("gamemode"), lambda on: set_flag("gamemode", bool(on))))
        opts.add(switch_row("Warn me about programs that probably won't work", "Games with anti-cheat, for example.",
                            not has_flag("no-unsupported-warning"), lambda on: set_flag("no-unsupported-warning", not on)))
        self.widget.add(opts)
        self.progs = make_group("Programs", "Each Windows program has its own private space.")
        self.widget.add(self.progs)
        self.unsup = make_group("Known not to work", "These usually use anti-cheat software that blocks Linux.")
        self.widget.add(self.unsup)
        self.fill_unsupported()

    def fill_unsupported(self):
        path = "/usr/share/fuzion/unsupported.db"
        try:
            with open(path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    parts = line.split("|")
                    if len(parts) >= 3:
                        self.unsup.add(action_row(parts[1], parts[2]))
        except OSError:
            self.unsup.add(action_row("List not found"))

    def gather(self):
        t = os.path.join(self.ROOT, "template")
        d = {"base": os.path.exists(os.path.join(t, ".fuzion-base")),
             "runtimes": os.path.exists(os.path.join(t, ".fuzion-runtimes")),
             "dxvk": os.path.exists(os.path.join(t, ".fuzion-dxvk")), "progs": []}
        pdir = os.path.join(self.ROOT, "prefixes")
        try:
            names = sorted(os.listdir(pdir))
        except OSError:
            names = []
        for n in names:
            p = os.path.join(pdir, n)
            info = {}
            for line in C.read_text(os.path.join(p, "fuzion.info")).splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    info[k] = v
            rc, out = sh(["du", "-sh", p], 20)
            size = out.split()[0] if rc == 0 and out else "?"
            d["progs"].append({"id": n, "path": p, "source": info.get("source", ""), "created": info.get("created", "")[:10],
                               "size": size})
        return d

    def refresh(self):
        bg(self.gather, self.show)

    def show(self, d):
        if isinstance(d, Exception):
            return
        clear_group(self.tmpl, self.rows[:0] or [])
        for r in getattr(self, "tmpl_rows", []):
            self.tmpl.remove(r)
        self.tmpl_rows = []
        for label, ok, hint in (("Windows base", d["base"], "Created the first time you open a Windows program."),
                                ("Fonts and Visual C++", d["runtimes"], "Needed by many programs."),
                                ("Graphics (DirectX translation)", d["dxvk"], "Installed on computers with a graphics card.")):
            r = action_row(label, ("Ready" if ok else "Not installed yet") + " \u00b7 " + hint)
            self.tmpl.add(r)
            self.tmpl_rows.append(r)
        rr = action_row("Rebuild Windows support", "Removes the shared parts. They are rebuilt next time you open a Windows program.")
        rr.add_suffix(small_button("Rebuild", self.rebuild, "destructive-action"))
        self.tmpl.add(rr)
        self.tmpl_rows.append(rr)
        clear_group(self.progs, self.rows)
        for p in d["progs"]:
            title = re.sub(r"-[0-9a-f]{8}$", "", p["id"]).replace("_", " ")
            sub = " \u00b7 ".join(x for x in (p["size"], p["created"], os.path.dirname(p["source"])) if x)
            r = action_row(title, sub)
            r.add_suffix(small_button("Folder", lambda pp=p["path"]: spawn(["xdg-open", pp])))
            log = os.path.join(self.ROOT, "logs", p["id"] + ".log")
            if os.path.exists(log):
                r.add_suffix(small_button("Log", lambda lg=log: spawn(["xdg-open", lg])))
            r.add_suffix(small_button("Remove", lambda pp=p: self.remove(pp), "destructive-action"))
            self.progs.add(r)
            self.rows.append(r)
        if not d["progs"]:
            r = action_row("No Windows programs yet", "Open an .exe or .msi file and it will show up here.")
            self.progs.add(r)
            self.rows.append(r)

    def remove(self, p):
        def go():
            shutil.rmtree(p["path"], ignore_errors=True)
            self.refresh()
        self.win.confirm("Remove this program's space?", "Its settings and saved data inside this space are deleted. "
                         "The original installer file is not touched.", "Remove", go)

    def rebuild(self):
        def go():
            shutil.rmtree(os.path.join(self.ROOT, "template"), ignore_errors=True)
            self.win.toast("Windows support will be rebuilt next time it is needed")
            self.refresh()
        self.win.confirm("Rebuild Windows support?", "Programs already set up keep working. New programs will "
                         "download and install the shared parts again.", "Rebuild", go)


# ============================================================================ About
class AboutPage(Page):
    name, title, icon = "about", "About", "help-about-symbolic"
    SERVICES = [("NetworkManager", "NetworkManager.service", False), ("Bluetooth", "bluetooth.service", False),
                ("Login screen (SDDM)", "sddm.service", False), ("Power profiles", "power-profiles-daemon.service", False),
                ("UPower", "upower.service", False), ("Audio (PipeWire)", "pipewire.service", True)]

    def build(self):
        self.info_rows, self.svc_rows = [], []
        self.hw = make_group("This computer")
        self.widget.add(self.hw)
        self.svc = make_group("System services")
        self.widget.add(self.svc)
        self.upd = make_group("Updates")
        self.upd_rows = []
        self.check_row = action_row("Check for updates", "Looks for new versions of installed software.")
        self.check_row.add_suffix(small_button("Check", self.check_updates, "suggested-action"))
        self.upd.add(self.check_row)
        self.widget.add(self.upd)

    def gather(self):
        d = {}
        osr = {}
        for line in C.read_text("/etc/os-release").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                osr[k] = v.strip('"')
        d["os"] = "ArcOS Sonora" if os.path.exists("/usr/share/arcos") else osr.get("PRETTY_NAME", "Linux")
        d["base"] = osr.get("PRETTY_NAME", "")
        d["kernel"] = sh(["uname", "-r"])[1]
        d["host"] = sh(["hostname"])[1]
        cpu = ""
        for line in C.read_text("/proc/cpuinfo").splitlines():
            if line.startswith("model name"):
                cpu = line.split(":", 1)[1].strip()
                break
        n = sum(1 for line in C.read_text("/proc/cpuinfo").splitlines() if line.startswith("processor"))
        d["cpu"] = "%s (%d threads)" % (cpu or "Unknown", n)
        mem = {}
        for line in C.read_text("/proc/meminfo").splitlines():
            k, _s, v = line.partition(":")
            mem[k] = int(re.sub(r"\D", "", v) or 0)
        d["mem"] = "%.1f GB total, %.1f GB available" % (mem.get("MemTotal", 0) / 1048576, mem.get("MemAvailable", 0) / 1048576)
        rc, out = sh(["lspci", "-mm"])
        gpus = []
        for line in out.splitlines() if rc == 0 else []:
            if re.search(r"VGA|3D|Display", line):
                parts = re.findall(r'"([^"]*)"', line)
                if len(parts) >= 3:
                    gpus.append("%s %s" % (parts[1], parts[2]))
        d["gpu"] = "; ".join(gpus) or "Unknown"
        du = shutil.disk_usage("/")
        d["disk"] = "%.0f GB used of %.0f GB" % (du.used / 1e9, du.total / 1e9)
        try:
            up = float(C.read_text("/proc/uptime").split()[0])
            d["uptime"] = fmt_time(up)
        except (ValueError, IndexError):
            d["uptime"] = "?"
        d["svc"] = []
        for label, unit, user in self.SERVICES:
            cmd = ["systemctl"] + (["--user"] if user else []) + ["is-active", unit]
            d["svc"].append((label, unit, user, sh(cmd)[1].strip()))
        return d

    def refresh(self):
        bg(self.gather, self.show)

    def show(self, d):
        if isinstance(d, Exception):
            return
        clear_group(self.hw, self.info_rows)
        for label, val in (("System", d["os"]), ("Based on", d["base"]), ("Kernel", d["kernel"]),
                           ("Computer name", d["host"]), ("Processor", d["cpu"]), ("Memory", d["mem"]),
                           ("Graphics", d["gpu"]), ("Storage", d["disk"]), ("Up for", d["uptime"])):
            r = action_row(label, val)
            r.set_subtitle_selectable(True)
            self.hw.add(r)
            self.info_rows.append(r)
        clear_group(self.svc, self.svc_rows)
        for label, unit, user, state in d["svc"]:
            r = action_row(label, state or "unknown")
            if state != "active":
                r.add_css_class("warning")
            cmd = (["systemctl", "--user", "restart", unit] if user else ["pkexec", "systemctl", "restart", unit])
            r.add_suffix(small_button("Restart", lambda c=cmd: bg(lambda: sh(c, 30), lambda _r: self.refresh())))
            self.svc.add(r)
            self.svc_rows.append(r)

    def check_updates(self):
        if not have("checkupdates"):
            self.win.toast("checkupdates is not installed (package: pacman-contrib)")
            return
        self.win.toast("Checking for updates...")

        def done(res):
            rc, out = res
            clear_group(self.upd, self.upd_rows)
            lines = [ln for ln in out.splitlines() if ln.strip()] if rc == 0 else []
            r = action_row("Everything is up to date" if not lines else "%d updates available" % len(lines))
            if lines:
                r.add_suffix(small_button("Update\u2026", lambda: spawn(
                    ["foot", "sh", "-c", "sudo pacman -Syu; echo; read -p 'Done. Press Enter to close.' x"]), "suggested-action"))
            self.upd.add(r)
            self.upd_rows.append(r)
            for ln in lines[:25]:
                rr = action_row(ln.split(" ")[0], ln)
                self.upd.add(rr)
                self.upd_rows.append(rr)
        bg(lambda: sh(["checkupdates"], 90), done)


# ============================================================================ more helpers for the extra pages
def flag_file(name):
    return os.path.join(C.CFG, name)


def has_flag(name):
    return os.path.exists(flag_file(name))


def set_flag(name, on):
    os.makedirs(C.CFG, exist_ok=True)
    if on:
        open(flag_file(name), "a").close()
    else:
        try:
            os.remove(flag_file(name))
        except OSError:
            pass


def merge_json(path, updates):
    data = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        pass
    data.update(updates)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)


def pk(cmd, timeout=40):
    """Run an administrator command (asks for permission when needed)."""
    return sh(["pkexec"] + cmd, timeout)


# ============================================================================ Desktop & effects
class EffectsPage(Page):
    name, title, icon = "effects", "Desktop & Effects", "preferences-desktop-theme-symbolic"
    PRESETS = {"Best looks": dict(blur=True, shadows=True, animations=True, rounding=14),
               "Balanced": dict(blur=True, shadows=False, animations=True, rounding=12),
               "Fast (virtual machine / older PC)": dict(blur=False, shadows=False, animations=False, rounding=8)}

    def build(self):
        e = U.load()["effects"]
        self.rows = {}
        pg = make_group("Quick choice", "Pick one to change several effects at once.")
        for label, vals in self.PRESETS.items():
            r = action_row(label)
            r.add_suffix(small_button("Use", lambda v=vals: self.preset(v)))
            pg.add(r)
        self.widget.add(pg)
        g = make_group("Effects")
        for key, label, sub in (("blur", "Frosted glass blur", "Blurs what is behind the menu bar, Dock and menus."),
                                ("shadows", "Window shadows", None),
                                ("animations", "Animations", "Smooth opening, closing and switching.")):
            r = switch_row(label, sub, e.get(key, True), lambda on, k=key: self.set_(k, bool(on)))
            g.add(r)
            self.rows[key] = r
        self.round = Debounce(lambda v: self.set_("rounding", int(v)))
        self.gap = Debounce(lambda v: self.set_("gap", int(v)))
        self.border = Debounce(lambda v: self.set_("border", int(v)))
        g.add(scale_row("Corner roundness", 0, 30, 1, e.get("rounding", 14), lambda v: self.round(v)))
        g.add(scale_row("Space between windows", 0, 30, 1, e.get("gap", 10), lambda v: self.gap(v)))
        g.add(scale_row("Window outline", 0, 4, 1, e.get("border", 1), lambda v: self.border(v)))
        self.widget.add(g)

    def set_(self, key, value):
        if not self.busy:
            U.set_value("effects." + key, value)

    def preset(self, vals):
        for k, v in vals.items():
            U.set_value("effects." + k, v)
        self.busy = True
        for k in ("blur", "shadows", "animations"):
            self.rows[k].set_active(bool(vals[k]))
        self.busy = False
        self.win.toast("Effects updated")


# ============================================================================ Dock & menu bar
class ShellPage(Page):
    name, title, icon = "shell", "Dock & Menu Bar", "view-app-grid-symbolic"

    def build(self):
        g = make_group("ArcOS Shell", "The menu bar, Dock, Control Center, Spotlight, widgets and notifications.")
        for title, sub, cmd in (("Open ArcOS Shell settings", "Menu bar, Dock size and position, glass style, widgets.",
                                 ["qs", "-c", "MacShell", "ipc", "call", "settings", "open"]),
                                ("Choose a wallpaper", "Opens the wallpaper picker (Ctrl + Alt + W).",
                                 ["qs", "-c", "MacShell", "ipc", "call", "wallpapers", "toggle"]),
                                ("Edit desktop widgets", "Move or remove the weather, clock and calendar widgets.",
                                 ["qs", "-c", "MacShell", "ipc", "call", "widgets", "edit", "true"])):
            r = action_row(title, sub)
            r.add_suffix(small_button("Open", lambda c=cmd: spawn(c)))
            g.add(r)
        rr = action_row("Restart the shell", "Use this if the menu bar or Dock ever looks wrong.")
        rr.add_suffix(small_button("Restart", lambda: sh(["pkill", "-f", "qs -c MacShell"])))
        g.add(rr)
        self.widget.add(g)
        w = make_group("Window buttons", "Close, minimise and maximise buttons for the window you are using.")
        w.add(switch_row("Show window buttons", "A small pill with three round buttons above the active window.",
                         not has_flag("winbar-off"), self.toggle_winbar))
        self.widget.add(w)

    def toggle_winbar(self, on):
        set_flag("winbar-off", not on)
        if on:
            spawn(["arcos-winbar"])
        else:
            sh(["pkill", "-f", "arcos_winbar.py"])
            sh(["pkill", "-x", "arcos-winbar"])


# ============================================================================ Lock & login
class LockPage(Page):
    name, title, icon = "lock", "Lock & Login", "system-lock-screen-symbolic"

    def build(self):
        g = make_group("Lock screen", "ArcOS Sonora uses the MacLock lock screen. There is no other login screen.")
        g.add(switch_row("Lock the screen when the computer starts", "After a restart you sign in on the lock screen.",
                         has_flag("lock-on-boot"), lambda on: set_flag("lock-on-boot", bool(on))))
        r = action_row("Lock now", "Or press Super + L.")
        r.add_suffix(small_button("Lock", lambda: spawn(["sh", os.path.expanduser("~/.config/quickshell/MacLock/lock-via-ipc.sh")])))
        g.add(r)
        self.widget.add(g)
        cfg = U.load()["power"]
        times = PowerPage.TIMES

        def idx(sec):
            for i, (_l, s) in enumerate(times):
                if s == sec:
                    return i
            return 0
        i = make_group("Automatic locking")
        i.add(combo_row("Lock the screen after", [t[0] for t in times], idx(cfg.get("lock", 900)),
                        lambda n: U.set_value("power.lock", times[n][1])))
        self.widget.add(i)
        if os.environ.get("USER") == "liveuser":
            n = make_group("Live session")
            n.add(action_row("Password", "This trial session's password is: arcos"))
            self.widget.add(n)


# ============================================================================ Date & time
class DateTimePage(Page):
    name, title, icon = "datetime", "Date & Time", "preferences-system-time-symbolic"

    def build(self):
        self.ntp = switch_row("Set the time automatically", "Uses the internet.", False, self.on_ntp)
        g = make_group()
        g.add(self.ntp)
        self.zone = combo_row("Time zone", [], 0, self.on_zone, search=True)
        g.add(self.zone)
        self.clock = switch_row("24-hour clock", "For apps that follow the system setting.", True, self.on_clock)
        g.add(self.clock)
        self.now = action_row("Now")
        g.add(self.now)
        self.widget.add(g)
        self.zones = []

    def gather(self):
        rc, out = sh(["timedatectl", "show"])
        d = {"props": dict(l.split("=", 1) for l in out.splitlines() if "=" in l) if rc == 0 else {}}
        if not self.zones:
            rc, out = sh(["timedatectl", "list-timezones"], 10)
            d["zones"] = out.split() if rc == 0 else []
        rc, out = sh(["gsettings", "get", "org.gnome.desktop.interface", "clock-format"])
        d["h24"] = "24h" in out
        return d

    def refresh(self):
        bg(self.gather, self.show)

    def show(self, d):
        if isinstance(d, Exception):
            return
        self.busy = True
        p = d["props"]
        self.ntp.set_active(p.get("NTP") == "yes")
        if d.get("zones") and not self.zones:
            self.zones = d["zones"]
            self.zone.set_model(Gtk.StringList.new(self.zones))
        if p.get("Timezone") in self.zones:
            self.zone.set_selected(self.zones.index(p["Timezone"]))
        self.clock.set_active(d["h24"])
        self.now.set_subtitle(GLib.markup_escape_text(p.get("TimeUSec", "")[:30]))
        self.busy = False

    def on_ntp(self, on):
        if not self.busy:
            bg(lambda: pk(["timedatectl", "set-ntp", "true" if on else "false"]), None)

    def on_zone(self, i):
        if not self.busy and 0 <= i < len(self.zones):
            bg(lambda: pk(["timedatectl", "set-timezone", self.zones[i]]), lambda _r: self.refresh())

    def on_clock(self, on):
        if not self.busy:
            sh(["gsettings", "set", "org.gnome.desktop.interface", "clock-format", "24h" if on else "12h"])


# ============================================================================ Language & region
class LanguagePage(Page):
    name, title, icon = "language", "Language & Region", "preferences-desktop-locale-symbolic"

    def build(self):
        rc, out = sh(["localectl", "status"])
        cur = ""
        for line in out.splitlines():
            if "LANG=" in line:
                cur = line.split("LANG=", 1)[1].split()[0]
        rc, out = sh(["locale", "-a"])
        self.locales = sorted({l for l in out.split() if l.lower().endswith(("utf8", "utf-8"))}) or ["en_US.utf8"]
        norm = lambda s: s.lower().replace("-", "")  # noqa: E731
        sel = next((i for i, l in enumerate(self.locales) if norm(l) == norm(cur)), 0)
        g = make_group("Language", "Takes effect the next time you sign in.")
        g.add(combo_row("Language and region", self.locales, sel, self.on_locale, search=True))
        self.widget.add(g)
        k = make_group()
        r = action_row("Keyboard layout", "Choose it under Keyboard & Mouse.")
        r.add_suffix(small_button("Open", lambda: self.win.open_page("input")))
        k.add(r)
        self.widget.add(k)

    def on_locale(self, i):
        loc = self.locales[i]
        bg(lambda: pk(["localectl", "set-locale", "LANG=" + loc]), lambda r: self.win.toast(
            "Language set to %s" % loc if r[0] == 0 else "Could not change the language"))


# ============================================================================ Default apps
class DefaultAppsPage(Page):
    name, title, icon = "defaults", "Default Apps", "preferences-desktop-default-applications-symbolic"
    KINDS = [("Web browser", ["x-scheme-handler/http", "x-scheme-handler/https", "text/html"]),
             ("File manager", ["inode/directory"]), ("Text editor", ["text/plain"]),
             ("Image viewer", ["image/png", "image/jpeg"]), ("Video player", ["video/mp4", "video/x-matroska"]),
             ("Music player", ["audio/mpeg", "audio/flac"])]

    def build(self):
        g = make_group("Open things with")
        for label, mimes in self.KINDS:
            apps = []
            try:
                apps = [a for a in Gio.AppInfo.get_all_for_type(mimes[0]) if a.should_show()]
            except Exception:  # noqa: BLE001
                pass
            if not apps:
                g.add(action_row(label, "No app installed for this yet"))
                continue
            cur = Gio.AppInfo.get_default_for_type(mimes[0], False)
            idx = next((i for i, a in enumerate(apps) if cur and a.get_id() == cur.get_id()), 0)
            g.add(combo_row(label, [a.get_display_name() for a in apps], idx,
                            lambda i, ap=apps, m=mimes: self.choose(ap[i], m)))
        self.widget.add(g)
        t = make_group("Shell shortcuts", "Used by the Dock, Spotlight and keyboard shortcuts.")
        terms = [x for x in ("foot", "kitty", "alacritty", "konsole", "gnome-terminal") if have(x)] or ["foot"]
        cfg = os.path.expanduser("~/.config/macbar/settings.json")
        t.add(combo_row("Terminal", terms, 0, lambda i: merge_json(cfg, {"terminal": terms[i]})))
        fm = [x for x in ("thunar", "nautilus", "dolphin", "pcmanfm-qt", "nemo") if have(x)] or ["thunar"]
        t.add(combo_row("File manager command", fm, 0, lambda i: merge_json(cfg, {"filesCmd": fm[i]})))
        self.widget.add(t)

    def choose(self, app, mimes):
        for m in mimes:
            try:
                app.set_as_default_for_type(m)
            except Exception:  # noqa: BLE001
                log_error()
        self.win.toast("%s is now the default" % app.get_display_name())


# ============================================================================ Startup apps
class StartupPage(Page):
    name, title, icon = "startup", "Startup Apps", "system-run-symbolic"
    DIR = os.path.expanduser("~/.config/autostart")

    def build(self):
        self.rows = []
        self.g = make_group("Open when you sign in")
        add = action_row("Add an app")
        self.choices = []
        try:
            self.choices = sorted([a for a in Gio.AppInfo.get_all() if a.should_show()], key=lambda a: a.get_display_name().lower())
        except Exception:  # noqa: BLE001
            pass
        self.combo = Gtk.DropDown.new_from_strings([a.get_display_name() for a in self.choices] or ["(none)"])
        self.combo.set_valign(Gtk.Align.CENTER)
        add.add_suffix(self.combo)
        add.add_suffix(small_button("Add", self.add_app, "suggested-action"))
        self.g.add(add)
        self.widget.add(self.g)
        self.listing = make_group("Current startup apps")
        self.widget.add(self.listing)
        self.fill()

    def fill(self):
        clear_group(self.listing, self.rows)
        os.makedirs(self.DIR, exist_ok=True)
        for f in sorted(os.listdir(self.DIR)):
            if not f.endswith(".desktop"):
                continue
            path = os.path.join(self.DIR, f)
            name, hidden = f[:-8], False
            for line in C.read_text(path).splitlines():
                if line.startswith("Name="):
                    name = line.split("=", 1)[1]
                if line.strip() == "Hidden=true":
                    hidden = True
            r = switch_row(name, f, not hidden, lambda on, p=path: self.toggle(p, on))
            r.add_suffix(small_button("Remove", lambda p=path: self.remove(p), "destructive-action"))
            self.listing.add(r)
            self.rows.append(r)
        if not self.rows:
            r = action_row("Nothing opens automatically yet")
            self.listing.add(r)
            self.rows.append(r)

    def add_app(self):
        i = self.combo.get_selected()
        if not self.choices or i >= len(self.choices):
            return
        a = self.choices[i]
        cmd = (a.get_commandline() or "").replace("%U", "").replace("%u", "").replace("%F", "").replace("%f", "").strip()
        os.makedirs(self.DIR, exist_ok=True)
        with open(os.path.join(self.DIR, (a.get_id() or a.get_display_name()).replace("/", "_")), "w", encoding="utf-8") as fh:
            fh.write("[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n" % (a.get_display_name(), cmd))
        self.fill()

    def toggle(self, path, on):
        text = [l for l in C.read_text(path).splitlines() if l.strip() != "Hidden=true"]
        if not on:
            text.append("Hidden=true")
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(text) + "\n")

    def remove(self, path):
        try:
            os.remove(path)
        except OSError:
            pass
        self.fill()


# ============================================================================ Accessibility
class AccessPage(Page):
    name, title, icon = "access", "Accessibility", "preferences-desktop-accessibility-symbolic"

    def build(self):
        a = U.load()["access"]
        g = make_group("Seeing")
        txt = Debounce(lambda v: U.set_value("access.text_scale", round(v, 2)))
        cur = Debounce(lambda v: U.set_value("access.cursor_size", int(v)))
        g.add(scale_row("Text size", 0.8, 2.0, 0.05, a.get("text_scale", 1.0), lambda v: txt(v), "For apps that follow the system setting"))
        g.add(scale_row("Pointer size", 16, 64, 4, a.get("cursor_size", 24), lambda v: cur(v)))
        g.add(switch_row("High contrast", None, a.get("high_contrast"), lambda on: U.set_value("access.high_contrast", bool(on))))
        self.widget.add(g)
        m = make_group("Motion")
        m.add(switch_row("Reduce motion", "Turns off most animations.", a.get("reduce_motion"),
                         lambda on: U.set_value("access.reduce_motion", bool(on))))
        self.widget.add(m)


# ============================================================================ Keyboard shortcuts (reference)
class ShortcutsPage(Page):
    name, title, icon = "shortcuts", "Keyboard Shortcuts", "input-keyboard-symbolic"
    SECTIONS = [
        ("Search and apps", [("Search (Spotlight)", "Super + Space"), ("Clipboard history", "Super + V"),
                             ("Emoji", "Super + ."), ("Switch windows", "Alt + Tab"),
                             ("Terminal", "Super + Enter"), ("Files", "Super + E"), ("Web browser", "Super + B"),
                             ("System Settings", "Super + ,"), ("ArcOS Shell settings", "Super + Z")]),
        ("Windows", [("Close window", "Super + Q"), ("Full screen", "Super + F"),
                     ("Float / tile window", "Super + T"), ("Move window", "Super + drag"),
                     ("Resize window", "Super + right-drag"), ("Bring back minimised windows", "Super + M"),
                     ("Move focus", "Super + arrow keys")]),
        ("Workspaces", [("Go to workspace 1-5", "Super + 1 \u2026 5"), ("Send window to workspace", "Super + Shift + 1 \u2026 5")]),
        ("System", [("Lock the screen", "Super + L"), ("Dark / light mode", "Super + Shift + D"),
                    ("Screenshot (area)", "Print, or Super + Shift + S"), ("Screenshot (screen)", "Super + Shift + A"),
                    ("Wallpapers", "Ctrl + Alt + W"), ("Log out", "Super + Shift + M")]),
    ]

    def build(self):
        for title, items in self.SECTIONS:
            g = make_group(title)
            for label, keys in items:
                r = action_row(label)
                lab = Gtk.Label(label=keys)
                lab.add_css_class("dim-label")
                lab.set_valign(Gtk.Align.CENTER)
                r.add_suffix(lab)
                g.add(r)
            self.widget.add(g)


# ============================================================================ Services
class ServicesPage(Page):
    name, title, icon = "services", "Services & Privacy", "preferences-system-privacy-symbolic"
    UNITS = [("Bluetooth", "bluetooth.service", "Lets you connect Bluetooth devices."),
             ("Remote login (SSH)", "sshd.service", "Lets other computers sign in to this one. Off is safer."),
             ("Printing", "cups.service", "Needed to use printers."),
             ("Power profiles", "power-profiles-daemon.service", "Performance / Balanced / Power Saver."),
             ("Firewall", "ufw.service", "Blocks unwanted connections.")]

    def build(self):
        a = make_group("Radios")
        self.air = switch_row("Airplane mode", "Turns off Wi-Fi and Bluetooth.", False, self.on_air)
        a.add(self.air)
        self.widget.add(a)
        g = make_group("System services", "Changing these asks for permission.")
        self.rows = {}
        for label, unit, sub in self.UNITS:
            r = switch_row(label, sub, False, lambda on, u=unit: self.toggle(u, on))
            g.add(r)
            self.rows[unit] = r
        self.widget.add(g)

    def gather(self):
        d = {"units": {}}
        for _l, unit, _s in self.UNITS:
            if sh(["systemctl", "cat", unit])[0] != 0:
                d["units"][unit] = None
            else:
                d["units"][unit] = sh(["systemctl", "is-active", unit])[1].strip() == "active"
        rc, out = sh(["rfkill", "list"])
        d["air"] = rc == 0 and out.count("Soft blocked: yes") >= 1 and "Soft blocked: no" not in out
        return d

    def refresh(self):
        bg(self.gather, self.show)

    def show(self, d):
        if isinstance(d, Exception):
            return
        self.busy = True
        for unit, state in d["units"].items():
            r = self.rows[unit]
            r.set_sensitive(state is not None)
            if state is None:
                r.set_subtitle("Not installed")
            else:
                r.set_active(state)
        self.air.set_active(d["air"])
        self.busy = False

    def toggle(self, unit, on):
        if self.busy:
            return
        cmd = ["systemctl", "enable", "--now", unit] if on else ["systemctl", "disable", "--now", unit]
        bg(lambda: pk(cmd), lambda r: (self.win.toast("Done" if r[0] == 0 else "Could not change it"), self.refresh()))

    def on_air(self, on):
        if not self.busy:
            bg(lambda: sh(["rfkill", "block" if on else "unblock", "all"]), None)


# ============================================================================ window
PAGES = [NetworkPage, BluetoothPage, DisplayPage, SoundPage, PowerPage, AppearancePage, EffectsPage,
         ShellPage, InputPage, ShortcutsPage, AccessPage, DefaultAppsPage, StartupPage, LockPage,
         DateTimePage, LanguagePage, ServicesPage, WindowsPage, AboutPage]


class SettingsWindow(Adw.ApplicationWindow):
    def __init__(self, app, start_page):
        super().__init__(application=app)
        self.set_title("Settings")
        self.set_default_size(1040, 720)
        self.current = None
        self.pages = {}

        self.toasts = Adw.ToastOverlay()
        split = Adw.NavigationSplitView()
        self.toasts.set_child(split)
        self.set_content(self.toasts)

        # sidebar
        side_view = Adw.ToolbarView()
        side_header = Adw.HeaderBar()
        side_header.set_title_widget(Gtk.Label(label="Settings"))
        side_view.add_top_bar(side_header)
        self.sidebar = Gtk.ListBox()
        self.sidebar.add_css_class("navigation-sidebar")
        sw = Gtk.ScrolledWindow()
        sw.set_child(self.sidebar)
        side_view.set_content(sw)
        split.set_sidebar(Adw.NavigationPage.new(side_view, "Settings"))

        # content
        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        content_view = Adw.ToolbarView()
        content_view.add_top_bar(Adw.HeaderBar())
        content_view.set_content(self.stack)
        self.content_page = Adw.NavigationPage.new(content_view, "Settings")
        split.set_content(self.content_page)

        for cls in PAGES:
            try:
                page = cls(self)
            except Exception:  # noqa: BLE001
                log_error()
                continue
            self.pages[page.name] = page
            self.stack.add_named(page.widget, page.name)
            row = Gtk.ListBoxRow()
            row.page_name = page.name
            box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
            box.set_margin_top(8)
            box.set_margin_bottom(8)
            box.set_margin_start(6)
            box.set_margin_end(6)
            box.append(Gtk.Image.new_from_icon_name(page.icon))
            box.append(Gtk.Label(label=page.title, xalign=0))
            row.set_child(box)
            self.sidebar.append(row)
        self.sidebar.connect("row-selected", self.on_row)
        self.open_page(start_page if start_page in self.pages else "network")
        GLib.timeout_add_seconds(3, self.poll)
        self.connect("close-request", self.on_close)

    def open_page(self, name):
        child = self.sidebar.get_first_child()
        while child is not None:
            if getattr(child, "page_name", None) == name:
                self.sidebar.select_row(child)
                return
            child = child.get_next_sibling()

    def on_row(self, _lb, row):
        if row is None:
            return
        if self.current:
            self.pages[self.current].on_hide()
        self.current = row.page_name
        page = self.pages[self.current]
        self.stack.set_visible_child_name(self.current)
        self.content_page.set_title(page.title)
        page.on_show()

    def poll(self):
        if self.current and self.is_active():
            try:
                self.pages[self.current].refresh()
            except Exception:  # noqa: BLE001
                log_error()
        return True

    def on_close(self, *_):
        for p in self.pages.values():
            p.on_hide()
        return False

    # ---- dialogs and toasts
    def toast(self, text):
        self.toasts.add_toast(Adw.Toast.new(text))

    def confirm(self, heading, body, ok_label, callback):
        d = Adw.MessageDialog(transient_for=self, heading=heading, body=body)
        d.add_response("cancel", "Cancel")
        d.add_response("ok", ok_label)
        d.set_response_appearance("ok", Adw.ResponseAppearance.DESTRUCTIVE)
        d.set_default_response("cancel")
        d.connect("response", lambda _d, r: callback() if r == "ok" else None)
        d.present()

    def ask_text(self, heading, body, placeholder, secret, ok_label, callback):
        d = Adw.MessageDialog(transient_for=self, heading=heading, body=body)
        entry = Gtk.PasswordEntry() if secret else Gtk.Entry()
        if not secret:
            entry.set_placeholder_text(placeholder)
        else:
            entry.set_show_peek_icon(True)
        d.set_extra_child(entry)
        d.add_response("cancel", "Cancel")
        d.add_response("ok", ok_label)
        d.set_response_appearance("ok", Adw.ResponseAppearance.SUGGESTED)
        d.set_default_response("ok")
        d.connect("response", lambda _d, r: callback(entry.get_text()) if r == "ok" and entry.get_text() else None)
        d.present()


class SettingsApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id="org.arcos.settings", flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.win = None

    def do_command_line(self, cmdline):
        args = cmdline.get_arguments()[1:]
        page = "network"
        if "--page" in args and args.index("--page") + 1 < len(args):
            page = args[args.index("--page") + 1]
        try:
            if self.win is None:
                self.win = SettingsWindow(self, page)
                self.win.connect("close-request", lambda *_: setattr(self, "win", None) or False)
            else:
                self.win.open_page(page)
            self.win.present()
        except Exception:  # noqa: BLE001
            log_error()
            self.quit()
            return 1
        return 0


if __name__ == "__main__":
    sys.exit(SettingsApp().run(sys.argv))
