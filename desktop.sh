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
# 2. Which Hyprland syntax do we need? (Hyprland 0.53 changed how window rules are written)
# ---------------------------------------------------------------------------
HYPR_VER="$( { pacman -Si hyprland 2>/dev/null || true; } | awk -F': *' '/^Version/ {print $2; exit}' | sed 's/^[0-9]*://; s/-.*//' || true )"
[ -n "$HYPR_VER" ] || HYPR_VER="0.53.0"
echo "==> Hyprland version in the Arch repository: $HYPR_VER"
if [ "$(printf '%s\n' 0.53.0 "$HYPR_VER" | sort -V | head -n1)" = "0.53.0" ]; then
  WINDOW_RULES='windowrule = float on, match:class .*
windowrule = center on, match:class .*
layerrule = blur on, match:namespace waybar
layerrule = ignore_alpha 0.2, match:namespace waybar
layerrule = blur on, match:namespace launcher
layerrule = ignore_alpha 0.2, match:namespace launcher
layerrule = blur on, match:namespace notifications
layerrule = ignore_alpha 0.2, match:namespace notifications
layerrule = blur on, match:namespace nwg-dock.*
layerrule = ignore_alpha 0.2, match:namespace nwg-dock.*'
else
  WINDOW_RULES='windowrulev2 = float, class:.*
windowrulev2 = center, class:.*
layerrule = blur, waybar
layerrule = ignorealpha 0.2, waybar
layerrule = blur, launcher
layerrule = ignorealpha 0.2, launcher
layerrule = blur, notifications
layerrule = ignorealpha 0.2, notifications
layerrule = blur, nwg-dock.*
layerrule = ignorealpha 0.2, nwg-dock.*'
fi

# ---------------------------------------------------------------------------
# 3. Hyprland: the main configuration
# ---------------------------------------------------------------------------
echo "==> Writing Hyprland configuration"
read -r -d '' HYPRCONF <<'HYPRCONF_EOF' || true
# =====================================================================
#  ArcOS Sonora - Hyprland configuration (made by Fuzion)
#  Every new user gets a copy of this file in ~/.config/hypr/
#  Lines starting with # are comments.
# =====================================================================

# Colors that change with dark / light mode (written by "arcos-theme")
source = ~/.config/hypr/colors.conf

# --- Screens -----------------------------------------------------------
# Use each screen's best resolution, placed automatically, no scaling.
monitor = , preferred, auto, 1

# --- Programs ----------------------------------------------------------
$terminal = foot
$files    = thunar
$browser  = firefox
$launcher = fuzzel
$mainMod  = SUPER

# --- Environment -------------------------------------------------------
env = XCURSOR_THEME,Adwaita
env = XCURSOR_SIZE,24
env = XDG_CURRENT_DESKTOP,Hyprland
env = XDG_SESSION_TYPE,wayland
env = XDG_SESSION_DESKTOP,Hyprland

# --- Programs that start automatically ---------------------------------
exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
exec-once = systemctl --user start hyprpolkitagent
exec-once = xdg-user-dirs-update
exec-once = arcos-theme apply                      # sets wallpaper + dark/light colors
exec-once = mako                                   # notifications
exec-once = waybar                                 # top bar
exec-once = bash ~/.config/hypr/scripts/dock.sh    # bottom dock
exec-once = nm-applet --indicator                  # Wi-Fi menu in the top bar
exec-once = blueman-applet                         # Bluetooth menu in the top bar
exec-once = wl-paste --type text --watch cliphist store
exec-once = wl-paste --type image --watch cliphist store
exec-once = hypridle                               # screen off / lock when idle

# --- Look ----------------------------------------------------------------
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 1
    col.active_border = rgba(3584e4cc)
    col.inactive_border = $border_inactive
    layout = dwindle
    resize_on_border = true
}

decoration {
    rounding = 14

    # Frosted-glass blur. If the desktop feels slow, set "enabled = false".
    blur {
        enabled = true
        size = 6
        passes = 2
        vibrancy = 0.15
        new_optimizations = true
        ignore_opacity = true
    }

    shadow {
        enabled = true
        range = 24
        render_power = 3
        color = $shadow_color
    }
}

animations {
    enabled = true
    bezier = ease, 0.25, 0.1, 0.25, 1.0
    bezier = pop, 0.05, 0.9, 0.1, 1.05
    animation = windows, 1, 5, pop, popin 90%
    animation = windowsOut, 1, 4, ease, popin 90%
    animation = fade, 1, 4, ease
    animation = layers, 1, 4, ease, fade
    animation = workspaces, 1, 5, ease, slide
}

dwindle {
    pseudotile = true
    preserve_split = true
}

misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
    force_default_wallpaper = 0
    vfr = true
}

cursor {
    no_hardware_cursors = 1
}

input {
    kb_layout = us
    follow_mouse = 1
    sensitivity = 0
    touchpad {
        natural_scroll = true
    }
}

# --- Window and layer rules (all windows float, like a normal desktop) ----
@WINDOW_RULES@

# --- Keyboard shortcuts -----------------------------------------------------
bind = $mainMod, SPACE, exec, $launcher                  # open the launcher
bind = $mainMod, RETURN, exec, $terminal                 # terminal
bind = $mainMod, E, exec, $files                         # files
bind = $mainMod, B, exec, $browser                       # web browser
bind = $mainMod, Q, killactive                           # close the window
bind = $mainMod, F, fullscreen, 0                        # fullscreen
bind = $mainMod, T, togglefloating                       # float / tile a window
bind = $mainMod, TAB, cyclenext                          # next window
bind = ALT, TAB, cyclenext
bind = $mainMod, L, exec, hyprlock                       # lock the screen
bind = $mainMod, V, exec, cliphist list | fuzzel --dmenu | cliphist decode | wl-copy
bind = $mainMod SHIFT, D, exec, arcos-theme toggle      # dark / light mode
bind = $mainMod SHIFT, S, exec, grim -g "$(slurp)" - | wl-copy
bind = $mainMod SHIFT, 3, exec, grim ~/Pictures/Screenshot-$(date +%F-%H%M%S).png
bind = $mainMod SHIFT, M, exit                           # log out

bind = $mainMod, 1, workspace, 1
bind = $mainMod, 2, workspace, 2
bind = $mainMod, 3, workspace, 3
bind = $mainMod, 4, workspace, 4
bind = $mainMod SHIFT, 1, movetoworkspace, 1
bind = $mainMod SHIFT, 2, movetoworkspace, 2
bind = $mainMod SHIFT, 4, movetoworkspace, 4

# Move and resize windows with the mouse while holding the SUPER key
bindm = $mainMod, mouse:272, movewindow
bindm = $mainMod, mouse:273, resizewindow

# Volume and brightness keys
bindel = , XF86AudioRaiseVolume, exec, wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+
bindel = , XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindl  = , XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
bindel = , XF86MonBrightnessUp, exec, brightnessctl set 5%+
bindel = , XF86MonBrightnessDown, exec, brightnessctl set 5%-
HYPRCONF_EOF
HYPRCONF="${HYPRCONF//@WINDOW_RULES@/$WINDOW_RULES}"
printf '%s\n' "$HYPRCONF" > "$CONF/hypr/hyprland.conf"

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

  cat > "$d/hypr-colors.conf" <<EOF
# Colors for $1 mode (written by arcos-theme)
\$border_inactive = $INACTIVE_BORDER
\$shadow_color = $SHADOW
EOF
}

# Dark mode
BAR_BG="rgba(24, 26, 46, 0.55)";  BAR_FG="#ffffff";  BAR_DIM="rgba(255, 255, 255, 0.55)"
TIP_BG="rgba(24, 26, 46, 0.92)";  TIP_BORDER="rgba(255, 255, 255, 0.14)"
FZ_BG="1b1d33e6"; FZ_TEXT="ffffffff"; FZ_BORDER="ffffff33"; ICON_THEME="Papirus-Dark"
MAKO_BG="#1b1d33e6"; MAKO_TEXT="#ffffff"; MAKO_BORDER="#ffffff33"
DOCK_BG="rgba(30, 32, 56, 0.55)"; DOCK_BORDER="rgba(255, 255, 255, 0.14)"; DOCK_HOVER="rgba(255, 255, 255, 0.14)"
INACTIVE_BORDER="rgba(ffffff22)"; SHADOW="rgba(00000066)"
make_theme dark

# Light mode
BAR_BG="rgba(248, 249, 253, 0.60)"; BAR_FG="#1c1c28"; BAR_DIM="rgba(28, 28, 40, 0.55)"
TIP_BG="rgba(248, 249, 253, 0.95)"; TIP_BORDER="rgba(0, 0, 0, 0.12)"
FZ_BG="f7f8fce6"; FZ_TEXT="1c1c28ff"; FZ_BORDER="00000022"; ICON_THEME="Papirus-Light"
MAKO_BG="#f7f8fce6"; MAKO_TEXT="#1c1c28"; MAKO_BORDER="#00000022"
DOCK_BG="rgba(255, 255, 255, 0.55)"; DOCK_BORDER="rgba(0, 0, 0, 0.10)"; DOCK_HOVER="rgba(0, 0, 0, 0.08)"
INACTIVE_BORDER="rgba(00000022)"; SHADOW="rgba(00000033)"
make_theme light

# New users start in dark mode
cp "$THEMES/dark/waybar-colors.css" "$CONF/waybar/colors.css"
cp "$THEMES/dark/fuzzel.ini"        "$CONF/fuzzel/fuzzel.ini"
cp "$THEMES/dark/mako.conf"         "$CONF/mako/config"
cp "$THEMES/dark/dock.css"          "$CONF/nwg-dock-hyprland/style.css"
cp "$THEMES/dark/hypr-colors.conf"  "$CONF/hypr/colors.conf"
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
cp -f "$T/hypr-colors.conf"  "$CFG/hypr/colors.conf"

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
  hyprctl reload >/dev/null 2>&1
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

START=$(date +%s)
Hyprland "$@"
STATUS=$?

if [ "$STATUS" -ne 0 ] && [ "$IN_VM" -eq 1 ] && [ $(( $(date +%s) - START )) -lt 15 ]; then
  export LIBGL_ALWAYS_SOFTWARE=1
  export WLR_RENDERER_ALLOW_SOFTWARE=1
  exec Hyprland "$@"
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
