#!/usr/bin/env bash
# desktop.sh - builds the ArcOS Sonora desktop: Hyprland + the MacShell shell
# (menu bar, Dock, Spotlight, Control Center, notifications, lock screen), restyled for ArcOS.
# This file is run by build.sh. It expects these variables from build.sh: HERE, PROFILE, AIR
set -euo pipefail

# Which MacShell to use. "main" = newest. You can pin a tag or commit, for example MACSHELL_REF=0.4.9
MACSHELL_REPO="${MACSHELL_REPO:-https://github.com/0-ss/MacShell}"
MACSHELL_REF="${MACSHELL_REF:-main}"
MACSHELL_SRC="${MACSHELL_SRC:-}"          # (testing only) use a local copy instead of downloading

SKEL="$AIR/etc/skel"
CONF="$SKEL/.config"
QS="$CONF/quickshell"
LIB="$AIR/usr/local/lib/arcos"
SYS="$AIR/etc/systemd/system"
WALL="$AIR/usr/share/backgrounds/arcos-sonora"

mkdir -p "$CONF/hypr" "$CONF/macbar" "$CONF/macdock" "$CONF/macshell" "$CONF/foot" "$CONF/gtk-3.0" \
         "$CONF/gtk-4.0" "$CONF/arcos" "$QS" "$LIB" "$WALL" "$AIR/usr/local/bin" \
         "$AIR/usr/share/applications" "$AIR/usr/share/wayland-sessions" "$AIR/usr/share/licenses/arcos" \
         "$SYS/multi-user.target.wants"

command -v python3 >/dev/null 2>&1 || pacman -S --noconfirm --needed python
command -v git >/dev/null 2>&1 || pacman -S --noconfirm --needed git

# ---------------------------------------------------------------------------
# 1. Wallpapers: ONLY these two ship with the OS (MacShell pairs "-Light" / "-Dark" by name)
# ---------------------------------------------------------------------------
echo "==> Installing the two ArcOS Sonora wallpapers"
for f in Sonora-Light.png Sonora-Dark.png; do
  [ -f "$HERE/$f" ] || { echo "ERROR: $f is missing from the repo. Upload it next to build.sh."; exit 1; }
  install -Dm644 "$HERE/$f" "$WALL/$f"
done
grep -q '^NoExtract' "$PROFILE/pacman.conf" || \
  sed -i '/^\[options\]/a NoExtract = usr/share/backgrounds/* usr/share/wallpapers/* usr/share/gnome-background-properties/*' \
    "$PROFILE/pacman.conf"

# ---------------------------------------------------------------------------
# 2. Download MacShell (MIT license) and put it where every new user gets it
# ---------------------------------------------------------------------------
if [ -z "$MACSHELL_SRC" ]; then
  echo "==> Downloading MacShell ($MACSHELL_REF) from $MACSHELL_REPO"
  MACSHELL_SRC=/tmp/macshell-src
  rm -rf "$MACSHELL_SRC"
  git clone --depth 1 --branch "$MACSHELL_REF" "$MACSHELL_REPO" "$MACSHELL_SRC"
  echo "==> MacShell commit: $(git -C "$MACSHELL_SRC" rev-parse HEAD)"
fi
for d in MacShell MacLock; do
  [ -d "$MACSHELL_SRC/$d" ] || { echo "ERROR: $d folder not found in MacShell. Its layout changed; tell Claude."; exit 1; }
done
mkdir -p "$QS/MacShell" "$QS/MacLock"
cp -a "$MACSHELL_SRC/MacShell/." "$QS/MacShell/"
cp -a "$MACSHELL_SRC/MacLock/."  "$QS/MacLock/"
rm -rf "$QS/MacShell/.git" "$QS/MacLock/.git"
[ -f "$MACSHELL_SRC/LICENSE" ] && install -Dm644 "$MACSHELL_SRC/LICENSE" "$AIR/usr/share/licenses/arcos/MacShell-LICENSE"
cat > "$AIR/usr/share/licenses/arcos/README-credits.txt" <<EOF
ArcOS Sonora (made by Fuzion) uses MacShell by Rickky (0-ss) and vSuol, MIT license:
$MACSHELL_REPO
The license text is in MacShell-LICENSE in this folder.
EOF

# ---------------------------------------------------------------------------
# 3. ArcOS look: icon theme, arc logo (menu bar), names
# ---------------------------------------------------------------------------
echo "==> Building the ArcOS Sonora icon theme"
ICONS="$AIR/usr/share/icons/ArcOS-Sonora"
python3 "$HERE/arcos_icons.py" "$ICONS"

echo "==> Replacing the Apple logo with the arc"
found=0
while IFS= read -r f; do
  case "$(basename "$f")" in
    *black*) cp "$ICONS/logo/arc-logo-black.svg" "$f" ;;
    *)       cp "$ICONS/logo/arc-logo-white.svg" "$f" ;;
  esac
  echo "    replaced $f"; found=1
done < <(find "$QS/MacShell" -iname 'apple-logo*.svg')
[ "$found" = 1 ] || echo "WARNING: no apple-logo*.svg found in MacShell; the menu bar logo was not replaced."
rm -rf "$ICONS/logo"

echo "==> Replacing the Finder icon (if MacShell ships its own SVG one)"
while IFS= read -r f; do
  cp "$ICONS/scalable/apps/arcos.svg" "$f"; echo "    replaced $f"
done < <(find "$QS/MacShell" -iname '*finder*.svg')
find "$QS/MacShell" -iname '*finder*' ! -iname '*.svg' | sed 's/^/    NOT replaced (not an SVG): /' || true

echo "==> Renaming macOS words in MacShell (a list of what was found is printed)"
rename_text() {   # rename_text "from" "to"
  local n
  local files
  files=$( { grep -rlF --include='*.qml' --include='*.js' -- "$1" "$QS/MacShell" "$QS/MacLock" 2>/dev/null || true; } )
  if [ -n "$files" ]; then
    n=$(printf '%s\n' "$files" | wc -l)
    printf '%s\n' "$files" | xargs -d '\n' sed -i "s|$1|$2|g"
    echo "    '$1' -> '$2' in $n file(s)"
  fi
}
rename_text "About This Linux" "About ArcOS Sonora"
rename_text "About This Mac"   "About ArcOS Sonora"
rename_text '"Finder"'         '"Files"'     # only the visible word, not code names
echo "    macOS words still in the shell (for the next round of renaming):"
grep -rhoE --include='*.qml' 'About This [A-Za-z]+|App Store|Mac(OS|Book)?[A-Za-z ]{0,12}|Apple' "$QS/MacShell" 2>/dev/null \
  | sort | uniq -c | sort -rn | head -25 | sed 's/^/      /' || true


echo "==> Pinning System Settings in the Dock by default"
python3 - "$QS/MacShell" <<'PINPY'
import os, re, sys
d = sys.argv[1]
ARR = re.compile(r"""\[\s*(?:(?:"[^"\n]+"|'[^'\n]+')\s*,\s*)+(?:"[^"\n]+"|'[^'\n]+')\s*\]""")
done = False
for fn in sorted(os.listdir(d)):
    if not fn.endswith(".qml"):
        continue
    path = os.path.join(d, fn)
    src = open(path, encoding="utf-8").read()
    for m in ARR.finditer(src):
        before = src[max(0, m.start() - 160):m.start()].lower()
        if "pinned" in before or "defaultapps" in before or "dockapps" in before:
            items = re.findall(r"""["']([^"'\n]+)["']""", m.group(0))
            quote = m.group(0)[m.group(0).index(next(c for c in m.group(0) if c in "\"'"))]
            name = "arcos-settings.desktop" if any(i.endswith(".desktop") for i in items) else "arcos-settings"
            if name in items:
                done = True
                break
            new = m.group(0)[:-1].rstrip() + ", %s%s%s]" % (quote, name, quote)
            src = src[:m.start()] + new + src[m.end():]
            open(path, "w", encoding="utf-8").write(src)
            print("    added %s to the default Dock apps in %s (was: %s)" % (name, fn, ", ".join(items)))
            done = True
            break
    if done:
        break
if not done:
    print("    WARNING: could not find the Dock's default app list. Lines that mention 'pinned':")
    for fn in sorted(os.listdir(d)):
        if fn.endswith(".qml"):
            for n, line in enumerate(open(os.path.join(d, fn), encoding="utf-8"), 1):
                if "pinned" in line.lower():
                    print("      %s:%d: %s" % (fn, n, line.strip()[:150]))
                    if n > 400:
                        break
PINPY

# ---------------------------------------------------------------------------
# 4. MacShell settings for ArcOS (only keys MacShell documents)
# ---------------------------------------------------------------------------
cat > "$CONF/macbar/settings.json" <<'EOF'
{
  "terminal": "foot",
  "filesCmd": "thunar",
  "wallpaperDir": "/usr/share/backgrounds/arcos-sonora",
  "wallpaperCmd": "sh /usr/local/bin/arcos-wallpaper {}"
}
EOF
cat > "$CONF/macdock/settings.json" <<'EOF'
{
  "wallpaperPath": "/usr/share/backgrounds/arcos-sonora/Sonora-Dark.png"
}
EOF
cat > "$CONF/macshell/env" <<'EOF'
# Extra settings for the shell, one per line. Read by arcos-shell-start.
QS_ICON_THEME=ArcOS-Sonora
# For old graphics cards, remove the # on the next two lines:
#QSG_RHI_BACKEND=opengl
#QSG_RENDER_LOOP=basic
EOF

# ---------------------------------------------------------------------------
# 5. Hyprland configuration (Lua)
# ---------------------------------------------------------------------------
echo "==> Writing Hyprland configuration (Lua)"
cat > "$CONF/hypr/hyprland.lua" <<'HYPRLUA_EOF'
-- =====================================================================
--  ArcOS Sonora - Hyprland configuration (made by Fuzion)
--  Hyprland 0.55 and newer reads Lua. Every new user gets a copy of
--  this file in ~/.config/hypr/   Lines starting with -- are comments.
--  The menu bar, Dock, Spotlight and lock screen come from MacShell.
-- =====================================================================

-- Adds a shortcut only if this Hyprland version knows the action,
-- so one unknown name can never break the whole configuration.
local function bind_safe(keys, make_action, opts)
    local ok, action = pcall(make_action)
    if ok and action ~= nil then
        pcall(hl.bind, keys, action, opts)
    end
end

-- --- Screens -------------------------------------------------------------
hl.monitor({
    output = "",
    mode = "preferred",
    position = "auto",
    scale = "auto",
})

-- --- Programs ------------------------------------------------------------
local terminal    = "foot"
local fileManager = "thunar"
local browser     = "firefox"
local mainMod     = "SUPER"
local qs          = "qs -c MacShell ipc call "

-- --- Environment ---------------------------------------------------------
hl.env("XCURSOR_THEME", "Adwaita")
hl.env("XCURSOR_SIZE", "24")
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")

-- --- Programs that start automatically -------------------------------------
hl.on("hyprland.start", function()
    hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE")
    hl.exec_cmd("systemctl --user start hyprpolkitagent")
    hl.exec_cmd("xdg-user-dirs-update")
    hl.exec_cmd("arcos-ui apply")                      -- screens, keyboard, mouse, accent
    hl.exec_cmd("sh /usr/local/bin/arcos-shell-start") -- menu bar, Dock, Spotlight, wallpaper
    hl.exec_cmd("hypridle")                            -- screen off / lock when idle
end)

-- --- Look ----------------------------------------------------------------
hl.config({
    general = {
        gaps_in = 5,
        gaps_out = 10,
        border_size = 1,
        col = {
            active_border = "rgba(3584e4cc)",
            inactive_border = "rgba(ffffff22)",
        },
        resize_on_border = true,
        allow_tearing = false,
        layout = "dwindle",
    },

    decoration = {
        rounding = 14,
        rounding_power = 2,
        active_opacity = 1.0,
        inactive_opacity = 1.0,

        shadow = {
            enabled = true,
            range = 24,
            render_power = 3,
            color = 0x66000000,
        },

        -- The Dock and menu bar need blur on. If the desktop feels slow, set enabled = false.
        blur = {
            enabled = true,
            size = 6,
            passes = 2,
            vibrancy = 0.15,
        },
    },

    animations = {
        enabled = true,
    },
})

-- Animations (smooth and soft)
hl.curve("easeOutQuint", { type = "bezier", points = { {0.23, 1}, {0.32, 1} } })
hl.curve("easeInOutCubic", { type = "bezier", points = { {0.65, 0.05}, {0.36, 1} } })
hl.curve("linear", { type = "bezier", points = { {0, 0}, {1, 1} } })
hl.curve("almostLinear", { type = "bezier", points = { {0.5, 0.5}, {0.75, 1} } })
hl.curve("quick", { type = "bezier", points = { {0.15, 0}, {0.1, 1} } })
hl.curve("easy", { type = "spring", mass = 1, stiffness = 238.1191, damping = 24.21279333 })

hl.animation({ leaf = "global", enabled = true, speed = 10, bezier = "default" })
hl.animation({ leaf = "border", enabled = true, speed = 5.39, bezier = "easeOutQuint" })
hl.animation({ leaf = "windows", enabled = true, speed = 4.79, spring = "easy" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 4.1, spring = "easy", style = "popin 87%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.49, bezier = "linear", style = "popin 87%" })
hl.animation({ leaf = "fadeIn", enabled = true, speed = 1.73, bezier = "almostLinear" })
hl.animation({ leaf = "fadeOut", enabled = true, speed = 1.46, bezier = "almostLinear" })
hl.animation({ leaf = "fade", enabled = true, speed = 3.03, bezier = "quick" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 1.94, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "workspacesIn", enabled = true, speed = 1.21, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "workspacesOut", enabled = true, speed = 1.94, bezier = "almostLinear", style = "fade" })

hl.config({
    dwindle = {
        preserve_split = true,
    },
})

hl.config({
    misc = {
        force_default_wallpaper = 0,        -- no built-in wallpapers: ArcOS Sonora has its own
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        allow_session_lock_restore = true,  -- lets the lock screen recover if it ever crashes
    },
})

hl.config({
    input = {
        kb_layout = "us",
        follow_mouse = 1,
        sensitivity = 0,
        touchpad = {
            natural_scroll = true,
        },
    },
})

-- --- Window and layer rules ----------------------------------------------
-- All windows float, like on a normal desktop (press SUPER + T to tile one).
hl.window_rule({ name = "arcos-float-all", match = { class = ".*" }, float = true })
hl.window_rule({ name = "arcos-center-all", match = { class = ".*" }, center = true })
hl.window_rule({ name = "suppress-maximize-events", match = { class = ".*" }, suppress_event = "maximize" })
hl.window_rule({
    name = "fix-xwayland-drags",
    match = { class = "^$", title = "^$", xwayland = true, float = true, fullscreen = false, pin = false },
    no_focus = true,
})

-- Blur behind the MacShell glass surfaces (from the MacShell instructions)
hl.layer_rule({ name = "macdock",  match = { namespace = "macdock"  }, blur = true, ignore_alpha = 0.2,  no_anim = true })
hl.layer_rule({ name = "macspot",  match = { namespace = "macspot"  }, blur = true, ignore_alpha = 0.05, no_anim = true })
hl.layer_rule({ name = "macbarbg", match = { namespace = "macbarbg" }, blur = true, ignore_alpha = 0.05, no_anim = true })
hl.layer_rule({ name = "macshot",  match = { namespace = "macshot"  }, no_anim = true })

-- --- Keyboard shortcuts -----------------------------------------------------
-- MacShell
hl.bind(mainMod .. " + SPACE", hl.dsp.exec_cmd(qs .. "spotlight toggle"))       -- search
hl.bind(mainMod .. " + V", hl.dsp.exec_cmd(qs .. "spotlight clipboard"))        -- clipboard history
hl.bind(mainMod .. " + period", hl.dsp.exec_cmd(qs .. "spotlight emoji"))       -- emoji
hl.bind("ALT + TAB", hl.dsp.exec_cmd(qs .. "switcher next"))                    -- switch windows
hl.bind("CTRL + ALT + W", hl.dsp.exec_cmd(qs .. "wallpapers toggle"))           -- wallpapers
hl.bind("PRINT", hl.dsp.exec_cmd(qs .. "screenshot region"))                    -- screenshot
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.exec_cmd(qs .. "screenshot region"))
hl.bind(mainMod .. " + SHIFT + A", hl.dsp.exec_cmd(qs .. "screenshot screen"))
hl.bind(mainMod .. " + L", hl.dsp.exec_cmd("sh ~/.config/quickshell/MacLock/lock-via-ipc.sh"))  -- lock
hl.bind(mainMod .. " + Z", hl.dsp.exec_cmd(qs .. "settings open"))              -- ArcOS Shell settings
-- ArcOS
hl.bind(mainMod .. " + comma", hl.dsp.exec_cmd("arcos-settings"))               -- System Settings
hl.bind(mainMod .. " + SHIFT + D", hl.dsp.exec_cmd("arcos-theme toggle"))       -- dark / light
-- Apps and windows
hl.bind(mainMod .. " + RETURN", hl.dsp.exec_cmd(terminal))
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd(fileManager))
hl.bind(mainMod .. " + B", hl.dsp.exec_cmd(browser))
hl.bind(mainMod .. " + Q", hl.dsp.window.close())
hl.bind(mainMod .. " + M", hl.dsp.exec_cmd("arcos-winbar --restore"))             -- bring back minimised windows
hl.bind(mainMod .. " + T", hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + SHIFT + M", hl.dsp.exit())                               -- log out
bind_safe(mainMod .. " + F", function() return hl.dsp.window.fullscreen() end)

hl.bind(mainMod .. " + left", hl.dsp.focus({ direction = "left" }))
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "right" }))
hl.bind(mainMod .. " + up", hl.dsp.focus({ direction = "up" }))
hl.bind(mainMod .. " + down", hl.dsp.focus({ direction = "down" }))

for i = 1, 5 do
    hl.bind(mainMod .. " + " .. i, hl.dsp.focus({ workspace = i }))
    hl.bind(mainMod .. " + SHIFT + " .. i, hl.dsp.window.move({ workspace = i }))
end

-- Move and resize windows with the mouse while holding SUPER
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- Volume and brightness keys
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"), { locked = true, repeating = true })
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), { locked = true, repeating = true })
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%+"), { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%-"), { locked = true, repeating = true })
HYPRLUA_EOF

cat > "$CONF/hypr/hypridle.conf" <<'EOF'
general {
    lock_cmd = sh ~/.config/quickshell/MacLock/lock-via-ipc.sh
    before_sleep_cmd = loginctl lock-session
    after_sleep_cmd = hyprctl dispatch dpms on
}

listener {
    timeout = 600
    on-timeout = hyprctl dispatch dpms off
    on-resume = hyprctl dispatch dpms on
}

listener {
    timeout = 900
    on-timeout = loginctl lock-session
}
EOF

# ---------------------------------------------------------------------------
# 6. Terminal, GTK settings, default apps
# ---------------------------------------------------------------------------
cat > "$CONF/foot/foot.ini" <<'EOF'
[main]
font=JetBrains Mono:size=11
pad=12x10
EOF
for v in 3.0 4.0; do
cat > "$CONF/gtk-$v/settings.ini" <<'EOF'
[Settings]
gtk-font-name=Inter 10
gtk-icon-theme-name=ArcOS-Sonora
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
EOF
done
echo dark > "$CONF/arcos/mode"
: > "$CONF/arcos/lock-on-boot"    # lock screen at every start (change in Settings > Lock & Login)

cat >> "$AIR/etc/xdg/mimeapps.list" <<'EOF'
inode/directory=thunar.desktop
text/html=firefox.desktop
x-scheme-handler/http=firefox.desktop
x-scheme-handler/https=firefox.desktop
EOF

# ---------------------------------------------------------------------------
# 7. ArcOS tools: Settings app, scripts, session
# ---------------------------------------------------------------------------
echo "==> Installing ArcOS Settings and helper scripts"
for f in arcos_common.py arcos_ui.py arcos_settings.py arcos_winbar.py; do
  [ -f "$HERE/$f" ] || { echo "ERROR: $f is missing from the repo."; exit 1; }
  install -Dm644 "$HERE/$f" "$LIB/$f"
done
printf '#!/bin/sh\nexec python3 /usr/local/lib/arcos/arcos_settings.py "$@"\n' > "$AIR/usr/local/bin/arcos-settings"
printf '#!/bin/sh\nexec python3 /usr/local/lib/arcos/arcos_ui.py "$@"\n'       > "$AIR/usr/local/bin/arcos-ui"
printf '#!/bin/sh\nexec python3 /usr/local/lib/arcos/arcos_winbar.py "$@"\n'   > "$AIR/usr/local/bin/arcos-winbar"

cat > "$AIR/usr/share/applications/arcos-settings.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=System Settings
Comment=Network, Bluetooth, displays, sound, power and more
Exec=arcos-settings
Icon=preferences-system
StartupWMClass=org.arcos.settings
Categories=Settings;System;
Keywords=settings;preferences;network;wifi;bluetooth;display;sound;battery;keyboard;mouse;about;
Terminal=false
EOF

cat > "$AIR/usr/local/bin/arcos-wallpaper" <<'EOF'
#!/bin/sh
# arcos-wallpaper IMAGE - set the desktop wallpaper (MacShell calls this when you pick one)
img="$1"
[ -f "$img" ] || exit 1
mkdir -p "$HOME/.config/arcos"
echo "$img" > "$HOME/.config/arcos/current-wallpaper"
old=$(pgrep -x swaybg | tr '\n' ' ')
setsid swaybg -i "$img" -m fill >/dev/null 2>&1 &
sleep 0.6
[ -n "$old" ] && kill $old 2>/dev/null
exit 0
EOF

cat > "$AIR/usr/local/bin/arcos-theme" <<'EOF'
#!/bin/sh
# arcos-theme dark|light|toggle|apply - dark / light mode for apps, and the matching wallpaper
D="$HOME/.config/arcos"; mkdir -p "$D"
W=/usr/share/backgrounds/arcos-sonora
cur=$(cat "$D/mode" 2>/dev/null || echo dark)
case "${1:-apply}" in
  dark) mode=dark ;;
  light) mode=light ;;
  toggle) if [ "$cur" = dark ]; then mode=light; else mode=dark; fi ;;
  apply) mode=$cur ;;
  *) echo "Usage: arcos-theme dark|light|toggle|apply"; exit 1 ;;
esac
echo "$mode" > "$D/mode"
if [ "$mode" = dark ]; then scheme=prefer-dark; gtk=Adwaita-dark; img="$W/Sonora-Dark.png"
else scheme=prefer-light; gtk=Adwaita; img="$W/Sonora-Light.png"; fi
gsettings set org.gnome.desktop.interface color-scheme "$scheme" 2>/dev/null
gsettings set org.gnome.desktop.interface gtk-theme "$gtk" 2>/dev/null
gsettings set org.gnome.desktop.interface icon-theme ArcOS-Sonora 2>/dev/null
gsettings set org.gnome.desktop.interface cursor-theme Adwaita 2>/dev/null
gsettings set org.gnome.desktop.interface font-name 'Inter 10' 2>/dev/null
# Wallpaper: keep a custom one chosen in MacShell, otherwise use the Sonora picture for this mode
saved=$(cat "$D/current-wallpaper" 2>/dev/null)
case "$saved" in "$W"/*|"") sh /usr/local/bin/arcos-wallpaper "$img" ;; esac
exit 0
EOF

cat > "$AIR/usr/local/bin/arcos-shell-start" <<'EOF'
#!/bin/sh
# arcos-shell-start - starts the ArcOS shell (MacShell), then the window buttons, startup apps
# and the lock screen. If the shell crashes it retries with safer graphics settings.
# Everything is logged to ~/.cache/arcos/shell.log
LOGDIR="$HOME/.cache/arcos"; mkdir -p "$LOGDIR"; LOG="$LOGDIR/shell.log"
[ "$(pgrep -fc 'qs -c MacShell')" -gt 0 ] && exit 0
exec >>"$LOG" 2>&1
echo "=== $(date) arcos-shell-start"

export QT_QPA_PLATFORM=wayland
export QS_ICON_THEME=ArcOS-Sonora
if [ -f "$HOME/.config/macshell/env" ]; then
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    export "$line"
  done < "$HOME/.config/macshell/env"
fi
IN_VM=0
systemd-detect-virt -q 2>/dev/null && IN_VM=1
echo "in a virtual machine: $IN_VM"

# wait for the desktop to be ready
i=0
while [ $i -lt 50 ]; do hyprctl version >/dev/null 2>&1 && break; i=$((i+1)); sleep 0.2; done

# wallpaper first, so the glass has something to show
sh /usr/local/bin/arcos-theme apply >/dev/null 2>&1

problem_terminal() {
  echo "--- giving up; opening a help window"
  command -v foot >/dev/null 2>&1 || return 0
  foot --title "ArcOS shell problem" sh -c '
    echo "The ArcOS shell could not start."; echo
    sh /usr/local/bin/arcos-diagnose
    echo; echo "Take a photo or screenshot of this and send it to Claude."
    echo "Press Enter to close."; read x'
}

# Once the shell has been running for a few seconds, start everything that goes with it
post_start() {
  n=0
  while [ $n -lt 8 ]; do
    sleep 8
    if pgrep -f 'qs -c MacShell' >/dev/null 2>&1; then
      RUNDIR="${XDG_RUNTIME_DIR:-/tmp}"
      [ -e "$RUNDIR/arcos-session-started" ] && return 0
      touch "$RUNDIR/arcos-session-started"
      echo "--- the shell is up: starting window buttons, startup apps, lock screen"
      [ -e "$HOME/.config/arcos/winbar-off" ] || { setsid arcos-winbar >"$LOGDIR/winbar.log" 2>&1 & }
      command -v dex >/dev/null 2>&1 && { dex -a -s "$HOME/.config/autostart" >/dev/null 2>&1 & }
      if [ -e "$HOME/.config/arcos/lock-on-boot" ]; then
        sh "$HOME/.config/quickshell/MacLock/lock-via-ipc.sh"
      fi
      return 0
    fi
    n=$((n+1))
  done
}
post_start &

# stage 1 = normal, 2 = OpenGL (works in most virtual machines), 3 = software drawing
stage=1
[ "$IN_VM" = 1 ] && stage=2
fails=0
while :; do
  case $stage in
    2) export QSG_RHI_BACKEND=opengl QSG_RENDER_LOOP=basic ;;
    3) export QSG_RHI_BACKEND=opengl QSG_RENDER_LOOP=basic QT_QUICK_BACKEND=software LIBGL_ALWAYS_SOFTWARE=1 ;;
  esac
  echo "--- starting MacShell (graphics mode $stage)"
  start=$(date +%s)
  qs -c MacShell
  code=$?
  ran=$(( $(date +%s) - start ))
  echo "--- MacShell stopped after ${ran}s (exit code $code)"
  if [ "$ran" -lt 15 ]; then
    fails=$((fails+1))
    [ "$stage" -lt 3 ] && stage=$((stage+1))
    if [ "$fails" -ge 5 ]; then problem_terminal; exit 1; fi
  else
    fails=0
  fi
  sleep 1
done
EOF

cat > "$AIR/usr/local/bin/arcos-diagnose" <<'EOF'
#!/bin/sh
# arcos-diagnose - prints what is needed to work out why the shell did not start
LOG="$HOME/.cache/arcos/shell.log"
echo "== ArcOS diagnose  $(date)"
echo "-- virtual machine: $(systemd-detect-virt 2>/dev/null)"
echo "-- Hyprland: $(hyprctl version 2>/dev/null | head -n 1)"
echo "-- Quickshell: $(qs --version 2>&1 | head -n 1)"
echo "-- packages: $(pacman -Q quickshell hyprland qt6-base qt6-declarative qt6-shadertools 2>&1 | tr '\n' ' ')"
echo "-- MacShell files: $(ls "$HOME/.config/quickshell/MacShell" 2>&1 | head -n 8 | tr '\n' ' ')"
echo "-- graphics: $(lspci 2>/dev/null | grep -iE 'vga|3d' | head -n 2)"
echo "-- last lines of $LOG:"
tail -n 40 "$LOG" 2>&1
EOF

cat > "$AIR/usr/local/bin/arcos-session" <<'ARCOS_SESSION'
#!/bin/sh
# arcos-session - starts the ArcOS Sonora desktop (Hyprland).
# Inside a virtual machine it uses safer graphics settings, and if the desktop
# fails to start it retries once with software graphics.
IN_VM=0
if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -q; then
  IN_VM=1
  export AQ_NO_MODIFIERS=1
fi

# Newer Hyprland versions must be started through "start-hyprland"
if command -v start-hyprland >/dev/null 2>&1; then
  LAUNCH=start-hyprland
else
  LAUNCH=Hyprland
fi

START=$(date +%s)
$LAUNCH "$@"
STATUS=$?

if [ "$STATUS" -ne 0 ] && [ "$IN_VM" -eq 1 ] && [ $(( $(date +%s) - START )) -lt 15 ]; then
  export LIBGL_ALWAYS_SOFTWARE=1
  export WLR_RENDERER_ALLOW_SOFTWARE=1
  exec $LAUNCH "$@"
fi
exit "$STATUS"
ARCOS_SESSION

cat > "$AIR/usr/share/wayland-sessions/arcos-sonora.desktop" <<'EOF'
[Desktop Entry]
Name=ArcOS Sonora
Comment=The ArcOS Sonora desktop
Exec=sh /usr/local/bin/arcos-session
Type=Application
DesktopNames=Hyprland
EOF

cat > "$AIR/usr/local/bin/arcos-liveuser-setup" <<'EOF'
#!/bin/sh
# Prepares the live session user: copies the default desktop settings into the home
# folder and sets the trial password (arcos) used to unlock the lock screen.
mkdir -p /home/liveuser
cp -rn /etc/skel/. /home/liveuser/
chown -R liveuser:liveuser /home/liveuser
echo 'liveuser:arcos' | chpasswd 2>/dev/null || true
EOF

cat > "$SYS/arcos-liveuser-setup.service" <<'EOF'
[Unit]
Description=Prepare the live session user
After=systemd-sysusers.service systemd-tmpfiles-setup.service
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/bin/sh /usr/local/bin/arcos-liveuser-setup

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/arcos-liveuser-setup.service "$SYS/multi-user.target.wants/arcos-liveuser-setup.service"
ln -sf /usr/lib/systemd/system/power-profiles-daemon.service "$SYS/multi-user.target.wants/power-profiles-daemon.service"

# Start the ArcOS Sonora session automatically
cat > "$AIR/etc/sddm.conf.d/10-autologin.conf" <<'EOF'
[Autologin]
User=liveuser
Session=arcos-sonora
Relogin=true
EOF

# archiso only keeps file permissions that are listed
cat >> "$PROFILE/profiledef.sh" <<'EOF'
file_permissions+=(["/usr/local/bin/arcos-theme"]="0:0:755")
file_permissions+=(["/usr/local/bin/arcos-session"]="0:0:755")
file_permissions+=(["/usr/local/bin/arcos-liveuser-setup"]="0:0:755")
file_permissions+=(["/usr/local/bin/arcos-shell-start"]="0:0:755")
file_permissions+=(["/usr/local/bin/arcos-wallpaper"]="0:0:755")
file_permissions+=(["/usr/local/bin/arcos-settings"]="0:0:755")
file_permissions+=(["/usr/local/bin/arcos-ui"]="0:0:755")
file_permissions+=(["/usr/local/bin/arcos-winbar"]="0:0:755")
file_permissions+=(["/usr/local/bin/arcos-diagnose"]="0:0:755")
EOF

echo "==> Desktop setup done"
