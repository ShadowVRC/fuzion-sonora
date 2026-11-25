#!/usr/bin/env bash
# desktop.sh - builds the ArcOS Sonora desktop (Hyprland, macOS-inspired).
# This file is run by build.sh. It expects these variables from build.sh: HERE, PROFILE, AIR
set -euo pipefail

SKEL="$AIR/etc/skel"
CONF="$SKEL/.config"
THEMES="$AIR/usr/share/arcos/themes"
SYS="$AIR/etc/systemd/system"

mkdir -p "$CONF/hypr/scripts" "$CONF/waybar" "$CONF/fuzzel" "$CONF/mako" \
         "$CONF/nwg-dock-hyprland" "$CONF/foot" "$CONF/gtk-3.0" "$CONF/gtk-4.0" "$CONF/arcos" \
         "$SKEL/.cache" "$THEMES" "$AIR/usr/local/bin" "$AIR/usr/share/wayland-sessions" \
         "$AIR/usr/share/backgrounds/arcos-sonora" "$SYS/multi-user.target.wants"

# ---------------------------------------------------------------------------
# 1. Wallpapers: ONLY these two ship with the OS (day = light mode, night = dark mode)
# ---------------------------------------------------------------------------
echo "==> Installing the two ArcOS Sonora wallpapers"
for f in sonora-day.jpg sonora-night.jpg; do
  [ -f "$HERE/$f" ] || { echo "ERROR: $f is missing from the repo. Upload it next to build.sh."; exit 1; }
  install -Dm644 "$HERE/$f" "$AIR/usr/share/backgrounds/arcos-sonora/$f"
done
# Make sure no other wallpapers are ever installed by packages
sed -i '/^\[options\]/a NoExtract = usr/share/backgrounds/* usr/share/wallpapers/* usr/share/gnome-background-properties/*' \
  "$PROFILE/pacman.conf"

# ---------------------------------------------------------------------------
# 2. Hyprland: the main configuration (Hyprland 0.55 and newer reads Lua, not hyprland.conf)
# ---------------------------------------------------------------------------
HYPR_VER="$( { pacman -Si hyprland 2>/dev/null || true; } | awk -F': *' '/^Version/ {print $2; exit}' | sed 's/^[0-9]*://; s/-.*//' || true )"
echo "==> Hyprland version in the Arch repository: ${HYPR_VER:-unknown}"

echo "==> Writing Hyprland configuration (Lua)"
cat > "$CONF/hypr/hyprland.lua" <<'HYPRLUA_EOF'
-- =====================================================================
--  ArcOS Sonora - Hyprland configuration (made by Fuzion)
--  Hyprland 0.55 and newer reads Lua. Every new user gets a copy of
--  this file in ~/.config/hypr/   Lines starting with -- are comments.
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
-- Every screen uses its best resolution, placed automatically.
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
local launcher    = "fuzzel"
local mainMod     = "SUPER"

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
    hl.exec_cmd("arcos-theme apply")                       -- wallpaper + dark/light colors
    hl.exec_cmd("mako")                                    -- notifications
    hl.exec_cmd("waybar")                                  -- top bar
    hl.exec_cmd("bash $HOME/.config/hypr/scripts/dock.sh") -- bottom dock
    hl.exec_cmd("nm-applet --indicator")                   -- Wi-Fi menu in the top bar
    hl.exec_cmd("blueman-applet")                          -- Bluetooth menu in the top bar
    hl.exec_cmd("wl-paste --type text --watch cliphist store")
    hl.exec_cmd("wl-paste --type image --watch cliphist store")
    hl.exec_cmd("hypridle")                                -- screen off / lock when idle
end)

-- --- Look ----------------------------------------------------------------
-- (The border and shadow colors are switched by "arcos-theme" for dark / light mode.)
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

        -- Frosted-glass blur. If the desktop feels slow, set enabled = false.
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

-- Animations (smooth and soft, like macOS)
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
hl.animation({ leaf = "layers", enabled = true, speed = 3.81, bezier = "easeOutQuint" })
hl.animation({ leaf = "layersIn", enabled = true, speed = 4, bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "layersOut", enabled = true, speed = 1.5, bezier = "linear", style = "fade" })
hl.animation({ leaf = "fadeLayersIn", enabled = true, speed = 1.79, bezier = "almostLinear" })
hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 1.39, bezier = "almostLinear" })
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
        force_default_wallpaper = 0,    -- no built-in wallpapers: ArcOS Sonora has its own
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
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
hl.window_rule({
    name = "arcos-float-all",
    match = { class = ".*" },
    float = true,
})

hl.window_rule({
    name = "arcos-center-all",
    match = { class = ".*" },
    center = true,
})

hl.window_rule({
    name = "suppress-maximize-events",
    match = { class = ".*" },
    suppress_event = "maximize",
})

hl.window_rule({
    name = "fix-xwayland-drags",
    match = {
        class = "^$",
        title = "^$",
        xwayland = true,
        float = true,
        fullscreen = false,
        pin = false,
    },
    no_focus = true,
})

-- Frosted glass behind the top bar, launcher, notifications and dock
hl.layer_rule({
    name = "arcos-glass",
    match = { namespace = "^(waybar|launcher|notifications|nwg-dock.*)$" },
    blur = true,
    ignore_alpha = 0.2,
})

-- --- Keyboard shortcuts -----------------------------------------------------
hl.bind(mainMod .. " + SPACE", hl.dsp.exec_cmd(launcher))          -- open the launcher
hl.bind(mainMod .. " + RETURN", hl.dsp.exec_cmd(terminal))         -- terminal
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd(fileManager))           -- files
hl.bind(mainMod .. " + B", hl.dsp.exec_cmd(browser))               -- web browser
hl.bind(mainMod .. " + Q", hl.dsp.window.close())                  -- close the window
hl.bind(mainMod .. " + T", hl.dsp.window.float({ action = "toggle" }))  -- float / tile
hl.bind(mainMod .. " + L", hl.dsp.exec_cmd("hyprlock"))            -- lock the screen
hl.bind(mainMod .. " + V", hl.dsp.exec_cmd("cliphist list | fuzzel --dmenu | cliphist decode | wl-copy"))
hl.bind(mainMod .. " + SHIFT + D", hl.dsp.exec_cmd("arcos-theme toggle"))   -- dark / light mode
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.exec_cmd('grim -g "$(slurp)" - | wl-copy'))
hl.bind(mainMod .. " + SHIFT + A", hl.dsp.exec_cmd("grim ~/Pictures/Screenshot-$(date +%F-%H%M%S).png"))
hl.bind(mainMod .. " + SHIFT + M", hl.dsp.exit())                  -- log out

bind_safe(mainMod .. " + F", function() return hl.dsp.window.fullscreen() end)
bind_safe(mainMod .. " + TAB", function() return hl.dsp.window.cycle_next() end)
bind_safe("ALT + TAB", function() return hl.dsp.window.cycle_next() end)

-- Move focus with the arrow keys
hl.bind(mainMod .. " + left", hl.dsp.focus({ direction = "left" }))
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "right" }))
hl.bind(mainMod .. " + up", hl.dsp.focus({ direction = "up" }))
hl.bind(mainMod .. " + down", hl.dsp.focus({ direction = "down" }))

-- Workspaces: SUPER + 1..5 to switch, SUPER + SHIFT + 1..5 to send a window there
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

# Idle: screen off after 10 min, lock after 15 min
cat > "$CONF/hypr/hypridle.conf" <<'EOF'
general {
    lock_cmd = pidof hyprlock || hyprlock
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

# Lock screen: big clock, date, name and a password box over the blurred desktop
cat > "$CONF/hypr/hyprlock.conf" <<'EOF'
general {
    hide_cursor = true
}

background {
    monitor =
    path = screenshot
    blur_passes = 3
    blur_size = 7
    brightness = 0.7
}

label {
    monitor =
    text = cmd[update:1000] date +"%H:%M"
    font_size = 110
    font_family = Inter Bold
    color = rgba(255, 255, 255, 0.88)
    position = 0, 220
    halign = center
    valign = center
}

label {
    monitor =
    text = cmd[update:60000] date +"%A, %d %B"
    font_size = 22
    font_family = Inter
    color = rgba(255, 255, 255, 0.75)
    position = 0, 130
    halign = center
    valign = center
}

label {
    monitor =
    text = $USER
    font_size = 18
    font_family = Inter
    color = rgba(255, 255, 255, 0.9)
    position = 0, -110
    halign = center
    valign = center
}

input-field {
    monitor =
    size = 260, 44
    outline_thickness = 1
    rounding = 22
    dots_size = 0.25
    dots_spacing = 0.3
    inner_color = rgba(255, 255, 255, 0.14)
    outer_color = rgba(255, 255, 255, 0.30)
    font_color = rgb(255, 255, 255)
    fade_on_empty = false
    placeholder_text = Enter Password
    position = 0, -170
    halign = center
    valign = center
}
EOF

# Dock launcher script + the apps pinned to the dock
cat > "$CONF/hypr/scripts/dock.sh" <<'EOF'
#!/usr/bin/env bash
# Starts the bottom dock. The apps pinned to it are listed in ~/.cache/nwg-dock-pinned
# (one app per line). Right-click an app in the dock to pin or unpin it.
nwg-dock-hyprland -i 48 -mb 10 -c fuzzel || nwg-dock-hyprland
EOF
cat > "$SKEL/.cache/nwg-dock-pinned" <<'EOF'
firefox
thunar
foot
steam
EOF

# ---------------------------------------------------------------------------
# 4. Dark / light themes (the colors that "arcos-theme" switches between)
# ---------------------------------------------------------------------------
echo "==> Writing dark and light themes"
make_theme() {
  local d="$THEMES/$1"
  mkdir -p "$d"

  cat > "$d/waybar-colors.css" <<EOF
@define-color bar_bg $BAR_BG;
@define-color bar_fg $BAR_FG;
@define-color bar_dim $BAR_DIM;
@define-color tip_bg $TIP_BG;
@define-color tip_border $TIP_BORDER;
@define-color accent #3584e4;
EOF

  cat > "$d/fuzzel.ini" <<EOF
# ArcOS Sonora launcher (fuzzel) - $1 mode
[main]
font=Inter:size=13
prompt="  "
icon-theme=$ICON_THEME
width=40
lines=8
horizontal-pad=24
vertical-pad=18
inner-pad=8
terminal=foot
layer=overlay

[colors]
background=$FZ_BG
text=$FZ_TEXT
match=3584e4ff
selection=3584e4ff
selection-text=ffffffff
selection-match=ffffffff
border=$FZ_BORDER

[border]
width=1
radius=18
EOF

  cat > "$d/mako.conf" <<EOF
# ArcOS Sonora notifications (mako) - $1 mode
font=Inter 11
background-color=$MAKO_BG
text-color=$MAKO_TEXT
border-color=$MAKO_BORDER
border-size=1
border-radius=14
padding=14
margin=12
width=360
default-timeout=6000
anchor=top-right
icons=1
max-icon-size=48
progress-color=over #3584e4
EOF

  cat > "$d/dock.css" <<EOF
/* ArcOS Sonora dock - $1 mode */
window {
  background: transparent;
}
#box {
  background: $DOCK_BG;
  border-radius: 22px;
  border: 1px solid $DOCK_BORDER;
  padding: 6px 10px;
}
button {
  background: transparent;
  border: none;
  box-shadow: none;
  padding: 4px;
  margin: 0 2px;
  border-radius: 14px;
}
button:hover {
  background: $DOCK_HOVER;
}
#active {
  background: $DOCK_HOVER;
}
image {
  background: none;
}
EOF

  # Window border + shadow colors, applied live with "hyprctl eval"
  cat > "$d/hypr.lua" <<EOF
hl.config({ general = { col = { inactive_border = "$INACTIVE_BORDER" } }, decoration = { shadow = { color = $SHADOW } } })
EOF
}

# Dark mode
BAR_BG="rgba(24, 26, 46, 0.55)";  BAR_FG="#ffffff";  BAR_DIM="rgba(255, 255, 255, 0.55)"
TIP_BG="rgba(24, 26, 46, 0.92)";  TIP_BORDER="rgba(255, 255, 255, 0.14)"
FZ_BG="1b1d33e6"; FZ_TEXT="ffffffff"; FZ_BORDER="ffffff33"; ICON_THEME="Papirus-Dark"
MAKO_BG="#1b1d33e6"; MAKO_TEXT="#ffffff"; MAKO_BORDER="#ffffff33"
DOCK_BG="rgba(30, 32, 56, 0.55)"; DOCK_BORDER="rgba(255, 255, 255, 0.14)"; DOCK_HOVER="rgba(255, 255, 255, 0.14)"
INACTIVE_BORDER="rgba(ffffff22)"; SHADOW="0x66000000"
make_theme dark

# Light mode
BAR_BG="rgba(248, 249, 253, 0.60)"; BAR_FG="#1c1c28"; BAR_DIM="rgba(28, 28, 40, 0.55)"
TIP_BG="rgba(248, 249, 253, 0.95)"; TIP_BORDER="rgba(0, 0, 0, 0.12)"
FZ_BG="f7f8fce6"; FZ_TEXT="1c1c28ff"; FZ_BORDER="00000022"; ICON_THEME="Papirus-Light"
MAKO_BG="#f7f8fce6"; MAKO_TEXT="#1c1c28"; MAKO_BORDER="#00000022"
DOCK_BG="rgba(255, 255, 255, 0.55)"; DOCK_BORDER="rgba(0, 0, 0, 0.10)"; DOCK_HOVER="rgba(0, 0, 0, 0.08)"
INACTIVE_BORDER="rgba(00000022)"; SHADOW="0x33000000"
make_theme light

# New users start in dark mode
cp "$THEMES/dark/waybar-colors.css" "$CONF/waybar/colors.css"
cp "$THEMES/dark/fuzzel.ini"        "$CONF/fuzzel/fuzzel.ini"
cp "$THEMES/dark/mako.conf"         "$CONF/mako/config"
cp "$THEMES/dark/dock.css"          "$CONF/nwg-dock-hyprland/style.css"
echo dark > "$CONF/arcos/mode"

# ---------------------------------------------------------------------------
# 5. Top bar (waybar)
# ---------------------------------------------------------------------------
echo "==> Writing the top bar"
cat > "$CONF/waybar/config.jsonc" <<'EOF'
// ArcOS Sonora top bar (waybar). Left: logo, active app, workspaces. Right: status and clock.
{
  "layer": "top",
  "position": "top",
  "height": 30,
  "spacing": 4,

  "modules-left": ["custom/logo", "hyprland/window", "hyprland/workspaces"],
  "modules-center": [],
  "modules-right": ["tray", "custom/theme", "bluetooth", "network", "pulseaudio", "battery", "clock"],

  "custom/logo": {
    "format": "ArcOS",
    "tooltip": false,
    "on-click": "fuzzel"
  },

  "hyprland/window": {
    "format": "{class}",
    "max-length": 36,
    "separate-outputs": true
  },

  "hyprland/workspaces": {
    "format": "{icon}",
    "format-icons": { "active": "\u25cf", "default": "\u25cb" },
    "all-outputs": true
  },

  "tray": { "icon-size": 16, "spacing": 10 },

  "custom/theme": {
    "exec": "arcos-theme icon",
    "interval": "once",
    "signal": 8,
    "tooltip-format": "Switch between dark and light mode",
    "on-click": "arcos-theme toggle"
  },

  "bluetooth": {
    "format": "\uf294",
    "format-disabled": "",
    "format-off": "",
    "format-connected": "\uf294 {num_connections}",
    "tooltip-format": "Bluetooth",
    "on-click": "blueman-manager"
  },

  "network": {
    "format-wifi": "\uf1eb",
    "format-ethernet": "\uf796",
    "format-disconnected": "\uf071",
    "tooltip-format": "{essid} {ifname} {ipaddr}",
    "on-click": "nm-connection-editor"
  },

  "pulseaudio": {
    "format": "{icon}",
    "format-muted": "\uf6a9",
    "format-icons": { "default": ["\uf027", "\uf028"] },
    "tooltip-format": "Volume {volume}%",
    "on-click": "pavucontrol"
  },

  "battery": {
    "format": "{capacity}% {icon}",
    "format-charging": "{capacity}% \uf0e7",
    "format-icons": ["\uf244", "\uf243", "\uf242", "\uf241", "\uf240"],
    "states": { "warning": 25, "critical": 12 }
  },

  "clock": {
    "format": "{:%a %b %e  %H:%M}",
    "tooltip-format": "{:%A, %d %B %Y}"
  }
}
EOF

cat > "$CONF/waybar/style.css" <<'EOF'
/* ArcOS Sonora top bar. Colors come from colors.css (changes with dark / light mode). */
@import url("colors.css");

* {
  font-family: "Inter", "Font Awesome 6 Free", "Font Awesome 6 Brands", sans-serif;
  font-size: 13px;
  border: none;
  border-radius: 0;
  min-height: 0;
}

window#waybar {
  background: @bar_bg;
  color: @bar_fg;
}

#custom-logo {
  font-weight: 700;
  padding: 0 14px;
}

#window {
  font-weight: 600;
  padding: 0 8px;
}

#workspaces button {
  padding: 0 5px;
  color: @bar_dim;
  background: transparent;
}

#workspaces button.active {
  color: @bar_fg;
}

#tray, #custom-theme, #bluetooth, #network, #pulseaudio, #battery, #clock {
  padding: 0 10px;
}

#clock {
  font-weight: 600;
}

#battery.warning { color: #f5c211; }
#battery.critical { color: #e01b24; }

tooltip {
  background: @tip_bg;
  border: 1px solid @tip_border;
  border-radius: 12px;
}
tooltip label {
  color: @bar_fg;
}
EOF

# ---------------------------------------------------------------------------
# 6. Terminal, GTK fonts and cursor
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
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
EOF
done

# ---------------------------------------------------------------------------
# 7. System scripts: theme switcher, session starter, live-user setup
# ---------------------------------------------------------------------------
echo "==> Writing system scripts"
cat > "$AIR/usr/local/bin/arcos-theme" <<'ARCOS_THEME'
#!/usr/bin/env bash
# arcos-theme - switch ArcOS Sonora between dark and light mode.
#   arcos-theme dark | light | toggle | apply | icon
# Switching changes: wallpaper, top bar, dock, launcher, notifications, window borders,
# and the dark/light setting that apps follow.
set -u

CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE="$CFG/arcos/mode"
SRC=/usr/share/arcos/themes
WALL=/usr/share/backgrounds/arcos-sonora

current() { cat "$STATE" 2>/dev/null || echo dark; }

case "${1:-apply}" in
  icon)   if [ "$(current)" = light ]; then printf '\xef\x86\x85\n'; else printf '\xef\x86\x86\n'; fi; exit 0 ;;
  dark)   MODE=dark ;;
  light)  MODE=light ;;
  toggle) if [ "$(current)" = dark ]; then MODE=light; else MODE=dark; fi ;;
  apply)  MODE="$(current)" ;;
  *)      echo "Usage: arcos-theme dark|light|toggle|apply"; exit 1 ;;
esac

mkdir -p "$CFG/arcos" "$CFG/waybar" "$CFG/fuzzel" "$CFG/mako" "$CFG/nwg-dock-hyprland" "$CFG/hypr"
echo "$MODE" > "$STATE"
T="$SRC/$MODE"

cp -f "$T/waybar-colors.css" "$CFG/waybar/colors.css"
cp -f "$T/fuzzel.ini"        "$CFG/fuzzel/fuzzel.ini"
cp -f "$T/mako.conf"         "$CFG/mako/config"
cp -f "$T/dock.css"          "$CFG/nwg-dock-hyprland/style.css"

# What apps follow
if [ "$MODE" = dark ]; then
  SCHEME=prefer-dark;  GTK=Adwaita-dark; ICONS=Papirus-Dark
else
  SCHEME=prefer-light; GTK=Adwaita;      ICONS=Papirus-Light
fi
gsettings set org.gnome.desktop.interface color-scheme "$SCHEME" 2>/dev/null
gsettings set org.gnome.desktop.interface gtk-theme "$GTK" 2>/dev/null
gsettings set org.gnome.desktop.interface icon-theme "$ICONS" 2>/dev/null
gsettings set org.gnome.desktop.interface cursor-theme Adwaita 2>/dev/null
gsettings set org.gnome.desktop.interface font-name 'Inter 10' 2>/dev/null

# Wallpaper: start the new one first, then remove the old one (no flicker)
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
  OLD="$(pgrep -x swaybg | tr '\n' ' ')"
  swaybg -i "$WALL/sonora-$([ "$MODE" = dark ] && echo night || echo day).jpg" -m fill >/dev/null 2>&1 &
  disown
  sleep 0.6
  [ -n "$OLD" ] && kill $OLD 2>/dev/null

  # Refresh whatever is already running
  pgrep -x waybar >/dev/null && pkill -SIGUSR2 waybar
  command -v makoctl >/dev/null 2>&1 && makoctl reload 2>/dev/null
  if pgrep -x nwg-dock-hyprland >/dev/null; then
    pkill -x nwg-dock-hyprland
    (bash "$CFG/hypr/scripts/dock.sh" >/dev/null 2>&1 &)
  fi
  [ -f "$T/hypr.lua" ] && hyprctl eval "$(cat "$T/hypr.lua")" >/dev/null 2>&1
  pgrep -x waybar >/dev/null && pkill -RTMIN+8 waybar
fi
exit 0
ARCOS_THEME

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
# folder and removes the password so the session can be unlocked with Enter.
mkdir -p /home/liveuser
cp -rn /etc/skel/. /home/liveuser/
chown -R liveuser:liveuser /home/liveuser
passwd -d liveuser >/dev/null 2>&1 || true
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

# Start the ArcOS Sonora session automatically
cat > "$AIR/etc/sddm.conf.d/10-autologin.conf" <<'EOF'
[Autologin]
User=liveuser
Session=arcos-sonora
EOF

# Default apps for common file types
cat >> "$AIR/etc/xdg/mimeapps.list" <<'EOF'
inode/directory=thunar.desktop
text/html=firefox.desktop
x-scheme-handler/http=firefox.desktop
x-scheme-handler/https=firefox.desktop
EOF

# archiso only keeps file permissions that are listed
cat >> "$PROFILE/profiledef.sh" <<'EOF'
file_permissions+=(["/usr/local/bin/arcos-theme"]="0:0:755")
file_permissions+=(["/usr/local/bin/arcos-session"]="0:0:755")
file_permissions+=(["/usr/local/bin/arcos-liveuser-setup"]="0:0:755")
EOF

echo "==> Desktop setup done"
