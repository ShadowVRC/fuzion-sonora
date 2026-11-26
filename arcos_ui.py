#!/usr/bin/env python3
"""arcos-ui - screens, interface scale, accent color, keyboard/mouse and idle settings for ArcOS Sonora.

   arcos-ui apply            apply everything saved in ~/.config/arcos/ui.json
   arcos-ui set KEY VALUE    save one setting (for example: arcos-ui set scale 1.25) and apply it
   arcos-ui get KEY          print one setting
   arcos-ui info             print the logical screen height
"""
import json
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, "/usr/local/lib/arcos")
import arcos_common as C  # noqa: E402

CFG_FILE = os.path.join(C.CFG, "ui.json")
LOCK_CMD = "sh ~/.config/quickshell/MacLock/lock-via-ipc.sh"   # the MacLock lock screen

DEFAULTS = {
    "scale": "auto",          # "auto" or a number such as "1.25"
    "accent": "blue",
    "monitors": {},           # per screen: {"mode": "1920x1080@60", "scale": "1", "transform": 0}
    "night_light": {"enabled": False, "temperature": 4500},
    "input": {"kb_layout": "us", "repeat_rate": 25, "repeat_delay": 600, "sensitivity": 0.0,
              "accel_profile": "adaptive", "natural_scroll": False,
              "touchpad_natural_scroll": True, "tap_to_click": True},
    "power": {"screen_off": 600, "lock": 900, "suspend": 0},
}


def load():
    try:
        with open(CFG_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        data = {}
    cfg = json.loads(json.dumps(DEFAULTS))
    for k, v in data.items():
        if isinstance(v, dict) and isinstance(cfg.get(k), dict):
            cfg[k].update(v)
        else:
            cfg[k] = v
    return cfg


def save(cfg):
    os.makedirs(C.CFG, exist_ok=True)
    with open(CFG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)


def run(cmd, timeout=8):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, str(e)


def in_session():
    return bool(os.environ.get("WAYLAND_DISPLAY")) and shutil.which("hyprctl") is not None


def hypr_eval(lua):
    if not in_session():
        return False
    rc, _ = run(["hyprctl", "eval", lua])
    return rc == 0


def monitors():
    if not in_session():
        return []
    rc, out = run(["hyprctl", "monitors", "-j"])
    try:
        return json.loads(out) if rc == 0 else []
    except ValueError:
        return []


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


# --- Screens ---------------------------------------------------------------------------------
def apply_monitors(cfg):
    mons = monitors()
    if not mons:
        return
    for m in mons:
        name = m.get("name")
        own = cfg.get("monitors", {}).get(name, {})
        scale = str(own.get("scale") or cfg.get("scale", "auto"))
        mode = own.get("mode") or "preferred"
        if not re.fullmatch(r"preferred|highres|highrr|\d+x\d+(@[\d.]+)?", mode):
            mode = "preferred"
        if not re.fullmatch(r"auto|[0-9]+(\.[0-9]+)?", scale):
            scale = "auto"
        transform = int(own.get("transform", 0)) % 8
        hypr_eval('hl.monitor({ output = "%s", mode = "%s", position = "auto", scale = "%s", transform = %d })'
                  % (name, mode, scale, transform))


# --- Accent color ----------------------------------------------------------------------------------
def apply_accent(cfg):
    name = cfg.get("accent", "blue")
    hexcol = C.ACCENTS.get(name, C.ACCENTS["blue"])
    os.makedirs(C.CFG, exist_ok=True)
    with open(os.path.join(C.CFG, "accent"), "w", encoding="utf-8") as f:
        f.write(hexcol)
    # Apps and window border
    if shutil.which("gsettings"):
        run(["gsettings", "set", "org.gnome.desktop.interface", "accent-color", name])
    hypr_eval('hl.config({ general = { col = { active_border = "rgba(%scc)" } } })' % hexcol.lstrip("#"))


# --- Keyboard, mouse and touchpad -------------------------------------------------------------------
def apply_input(cfg):
    i = cfg.get("input", {})
    layout = str(i.get("kb_layout", "us"))
    if not re.fullmatch(r"[A-Za-z0-9_,\-]+", layout):
        layout = "us"
    prof = "flat" if i.get("accel_profile") == "flat" else "adaptive"
    b = lambda v: "true" if v else "false"  # noqa: E731
    lua = ('hl.config({ input = { kb_layout = "%s", repeat_rate = %d, repeat_delay = %d, sensitivity = %.2f, '
           'accel_profile = "%s", natural_scroll = %s, touchpad = { natural_scroll = %s, tap_to_click = %s } } })'
           % (layout, int(i.get("repeat_rate", 25)), int(i.get("repeat_delay", 600)),
              float(i.get("sensitivity", 0.0)), prof, b(i.get("natural_scroll")),
              b(i.get("touchpad_natural_scroll", True)), b(i.get("tap_to_click", True))))
    hypr_eval(lua)


# --- Night light ----------------------------------------------------------------------------------------
def apply_night_light(cfg):
    nl = cfg.get("night_light", {})
    run(["pkill", "-x", "hyprsunset"])
    if nl.get("enabled") and shutil.which("hyprsunset"):
        temp = int(clamp(int(nl.get("temperature", 4500)), 1000, 6500))
        subprocess.Popen(["hyprsunset", "-t", str(temp)], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)


# --- Idle, screen off and lock ----------------------------------------------------------------------
def render_hypridle(cfg=None, restart=True):
    cfg = cfg or load()
    p = cfg.get("power", {})
    off, lock, susp = int(p.get("screen_off", 600)), int(p.get("lock", 900)), int(p.get("suspend", 0))
    text = """general {
    lock_cmd = @LOCK_CMD@
    before_sleep_cmd = loginctl lock-session
    after_sleep_cmd = hyprctl dispatch dpms on
}
"""
    if off > 0:
        text += """
listener {
    timeout = %d
    on-timeout = hyprctl dispatch dpms off
    on-resume = hyprctl dispatch dpms on
}
""" % off
    if lock > 0:
        text += """
listener {
    timeout = %d
    on-timeout = loginctl lock-session
}
""" % lock
    if susp > 0:
        text += """
listener {
    timeout = %d
    on-timeout = systemctl suspend
}
""" % susp
    text = text.replace("@LOCK_CMD@", LOCK_CMD)
    d = os.path.join(C.HOME, ".config", "hypr")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "hypridle.conf"), "w", encoding="utf-8") as f:
        f.write(text)
    if restart and in_session():
        run(["pkill", "-x", "hypridle"])
        subprocess.Popen(["hypridle"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)


# --- Put it all together ---------------------------------------------------------------------------------------
def apply_all():
    cfg = load()
    apply_monitors(cfg)
    apply_accent(cfg)
    apply_input(cfg)
    apply_night_light(cfg)


APPLY = {"scale": ("monitors",), "monitors": ("monitors",), "accent": ("accent",),
         "input": ("input",), "night_light": ("night_light",), "power": ("power",)}


def apply_part(cfg, part):
    {"monitors": apply_monitors, "accent": apply_accent, "input": apply_input,
     "night_light": apply_night_light, "power": lambda c: render_hypridle(c)}[part](cfg)


def set_value(key, value):
    cfg = load()
    node, parts = cfg, key.split(".")
    for p in parts[:-1]:
        node = node.setdefault(p, {})
    node[parts[-1]] = value
    save(cfg)
    for part in APPLY.get(parts[0], ()):
        apply_part(cfg, part)


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "apply"
    if cmd == "apply":
        apply_all()
    elif cmd == "accent":
        apply_accent(load())
    elif cmd == "set" and len(argv) >= 4:
        try:
            value = json.loads(argv[3])
        except ValueError:
            value = argv[3]
        set_value(argv[2], value)
    elif cmd == "get" and len(argv) >= 3:
        node = load()
        for p in argv[2].split("."):
            node = node.get(p) if isinstance(node, dict) else None
        print(node)
    elif cmd == "info":
        print(json.dumps({"logical_height": logical_height()}, indent=2))
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
