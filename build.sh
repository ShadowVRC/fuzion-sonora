#!/usr/bin/env bash
# Builds the Fuzion Sonora ISO. Runs inside GitHub Actions (an Arch Linux container).
set -euo pipefail

HERE="$PWD"
PROFILE="$HERE/profile"
WORKDIR=/tmp/fuzion-work

echo "==> Starting from Arch's official live-ISO profile"
rm -rf "$PROFILE"
cp -r /usr/share/archiso/configs/releng "$PROFILE"

echo "==> Branding"
sed -i 's/^iso_name=.*/iso_name="fuzion-sonora"/'                         "$PROFILE/profiledef.sh"
sed -i 's/^iso_publisher=.*/iso_publisher="Fuzion Sonora"/'                "$PROFILE/profiledef.sh"
sed -i 's/^iso_application=.*/iso_application="Fuzion Sonora Live ISO"/'   "$PROFILE/profiledef.sh"
sed -i 's/ARCH_/FUZION_/'                                                  "$PROFILE/profiledef.sh"
echo "fuzion-sonora" > "$PROFILE/airootfs/etc/hostname"

echo "==> Turning on 32-bit packages (needed for Steam and Wine)"
sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' "$PROFILE/pacman.conf"
grep -A1 '^\[multilib\]' "$PROFILE/pacman.conf" || { echo "multilib not enabled!"; exit 1; }

echo "==> Adding our packages"
echo >> "$PROFILE/packages.x86_64"
grep -v '^\s*#' "$HERE/packages.txt" | grep -v '^\s*$' >> "$PROFILE/packages.x86_64"

# Arch's list has the text-only VirtualBox tools; we use the full version (screen resizing, clipboard)
sed -i '/^virtualbox-guest-utils-nox$/d' "$PROFILE/packages.x86_64"

echo "==> Adding our config files into the system"
AIR="$PROFILE/airootfs"
mkdir -p "$AIR/etc/sddm.conf.d" "$AIR/etc/sysusers.d" "$AIR/etc/tmpfiles.d"

# Log straight into the desktop
cat > "$AIR/etc/sddm.conf.d/10-autologin.conf" <<'CONF'
[Autologin]
User=liveuser
Session=plasma
CONF

# Create the "liveuser" account
cat > "$AIR/etc/sysusers.d/liveuser.conf" <<'CONF'
u liveuser 1000 "Live User" /home/liveuser /bin/bash
CONF

# Create that user's home folder
cat > "$AIR/etc/tmpfiles.d/liveuser.conf" <<'CONF'
d /home/liveuser 0700 liveuser liveuser -
CONF

echo "==> Adding Windows app support (Fuzion Run)"
mkdir -p "$AIR/usr/local/bin" "$AIR/usr/share/applications" "$AIR/etc/xdg"

cat > "$AIR/usr/local/bin/fuzion-run" <<'FUZION_RUN'
#!/usr/bin/env bash
# fuzion-run v2: opens Windows programs (.exe and .msi) with no setup needed.
# - A shared "template" Windows environment is built once (fonts + Visual C++ runtimes).
# - Every program gets its own private copy of it, created automatically.
# - Per-program fixes come from /usr/share/fuzion/compat.db
set -u

FILE="${1:-}"
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  kdialog --error "Fuzion Sonora could not find that file."
  exit 1
fi

FILE="$(realpath "$FILE")"
BASE="$(basename "$FILE")"
NAME="${BASE%.*}"
EXT="${BASE##*.}"; EXT="${EXT,,}"
SAFE="$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-40)"
HASH="$(printf '%s' "$FILE" | sha1sum | cut -c1-8)"

ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/fuzion"
TEMPLATE="$ROOT/template"
PREFIX="$ROOT/prefixes/${SAFE}-${HASH}"
LOG="$ROOT/logs/${SAFE}-${HASH}.log"
SETUPLOG="$ROOT/logs/setup.log"
DB=/usr/share/fuzion/compat.db
mkdir -p "$ROOT/prefixes" "$ROOT/logs"

export WINEARCH=win64
export WINEDEBUG=-all

notify() { kdialog --passivepopup "$1" "${2:-6}" >/dev/null 2>&1 & }
online() { curl -fsS --max-time 5 -o /dev/null https://archlinux.org 2>/dev/null; }
has_gpu_vulkan() {
  command -v vulkaninfo >/dev/null 2>&1 || return 1
  vulkaninfo --summary 2>/dev/null | grep deviceType | grep -qv 'TYPE_CPU'
}

# Build the shared template once (and finish it later if we were offline)
build_template() {
  (
    flock 9
    export WINEPREFIX="$TEMPLATE"
    if [ ! -f "$TEMPLATE/.fuzion-base" ]; then
      notify "Preparing Windows support for the first time. This can take a few minutes." 12
      wineboot -u >>"$SETUPLOG" 2>&1 || exit 1
      wineserver -w
      touch "$TEMPLATE/.fuzion-base"
    fi
    if [ ! -f "$TEMPLATE/.fuzion-runtimes" ] && online; then
      notify "Installing Windows components (fonts and Visual C++)..." 12
      if winetricks -q corefonts vcrun2022 >>"$SETUPLOG" 2>&1; then
        touch "$TEMPLATE/.fuzion-runtimes"
      fi
      wineserver -w
    fi
    # DirectX translation only makes sense with a real GPU
    if [ ! -f "$TEMPLATE/.fuzion-dxvk" ] && online && has_gpu_vulkan; then
      if winetricks -q dxvk >>"$SETUPLOG" 2>&1; then
        touch "$TEMPLATE/.fuzion-dxvk"
      fi
      wineserver -w
    fi
  ) 9>"$ROOT/template.lock"
}

# Apply per-program fixes from the compatibility database
apply_compat() {
  [ -f "$DB" ] || return 0
  local lname="${BASE,,}" pat verbs envs kv
  while IFS='|' read -r pat verbs envs; do
    case "$pat" in ''|\#*) continue ;; esac
    case "$lname" in
      $pat)
        if [ "${verbs:--}" != "-" ] && ! grep -qxF "$verbs" "$PREFIX/fuzion.applied" 2>/dev/null; then
          if online && winetricks -q $verbs >>"$LOG" 2>&1; then
            echo "$verbs" >> "$PREFIX/fuzion.applied"
          fi
          wineserver -w
        fi
        if [ "${envs:--}" != "-" ]; then
          for kv in $envs; do export "$kv"; done
        fi
        ;;
    esac
  done < "$DB"
}

# First time for this program: make its own environment from the template
if [ ! -d "$PREFIX/drive_c" ]; then
  if ! build_template; then
    kdialog --error "Fuzion Sonora could not set up Windows support."
    exit 1
  fi
  notify "Setting up $NAME. This only happens once." 8
  cp -a --reflink=auto "$TEMPLATE" "$PREFIX"
  rm -f "$PREFIX"/.fuzion-base "$PREFIX"/.fuzion-runtimes "$PREFIX"/.fuzion-dxvk
  export WINEPREFIX="$PREFIX"
  wineboot -u >>"$LOG" 2>&1
  wineserver -w
  {
    echo "source=$FILE"
    echo "created=$(date -Is)"
  } > "$PREFIX/fuzion.info"
fi

export WINEPREFIX="$PREFIX"
apply_compat

START=$SECONDS
case "$EXT" in
  msi) wine msiexec /i "$FILE" >>"$LOG" 2>&1 ;;
  exe) cd "$(dirname "$FILE")" && wine "$FILE" >>"$LOG" 2>&1 ;;
  *)   kdialog --error "Fuzion Sonora can't open this type of file yet."; exit 1 ;;
esac
STATUS=$?

# If it failed almost instantly, tell the user in plain language
if [ "$STATUS" -ne 0 ] && [ $((SECONDS - START)) -lt 5 ]; then
  kdialog --sorry "$NAME couldn't be started. It may not be supported yet."
fi
exit 0
FUZION_RUN

mkdir -p "$AIR/usr/share/fuzion"
cat > "$AIR/usr/share/fuzion/compat.db" <<'COMPATDB'
# Fuzion Sonora compatibility database
#
# One program per line:   file-name pattern | extra components | settings
#   - The pattern is lowercase; * matches anything.
#   - Extra components are winetricks names (for example: dotnet48). Use - for none.
#   - Settings are NAME=value pairs separated by spaces. Use - for none.
#
# This list is empty on purpose. Entries get added once they are tested on real hardware.
# Examples (switched off):
# somegame*.exe|vcrun2019|WINEDEBUG=-all
# someapp-setup.exe|corefonts|-
COMPATDB

echo "==> Fixing the language setting (locale)"
mkdir -p "$AIR/etc/systemd/system"
cat > "$AIR/etc/locale.gen" <<'LOC'
en_US.UTF-8 UTF-8
LOC
echo "LANG=en_US.UTF-8" > "$AIR/etc/locale.conf"
cat > "$AIR/etc/systemd/system/fuzion-locale.service" <<'UNIT'
[Unit]
Description=Generate system language data
Before=display-manager.service
ConditionPathExists=!/usr/lib/locale/locale-archive

[Service]
Type=oneshot
ExecStart=/usr/bin/locale-gen

[Install]
WantedBy=multi-user.target
UNIT


cat > "$AIR/usr/share/applications/fuzion-windows-app.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=Windows Application
Comment=Run Windows programs
Exec=fuzion-run %f
Icon=wine
MimeType=application/x-ms-dos-executable;application/vnd.microsoft.portable-executable;application/x-msdownload;application/x-dosexec;application/x-msi;
NoDisplay=true
Terminal=false
DESK

# Make it the default way to open Windows files
cat > "$AIR/etc/xdg/mimeapps.list" <<'MIME'
[Default Applications]
application/x-ms-dos-executable=fuzion-windows-app.desktop
application/vnd.microsoft.portable-executable=fuzion-windows-app.desktop
application/x-msdownload=fuzion-windows-app.desktop
application/x-dosexec=fuzion-windows-app.desktop
application/x-msi=fuzion-windows-app.desktop
MIME

# Let the script run (archiso only keeps permissions that are listed)
echo 'file_permissions+=(["/usr/local/bin/fuzion-run"]="0:0:755")' >> "$PROFILE/profiledef.sh"

echo "==> Giving the live session more room to write files (Steam needs space)"
sed -i 's/^options .*/& cow_spacesize=4G/' "$PROFILE"/efiboot/loader/entries/*.conf 2>/dev/null || true
sed -i 's/^APPEND .*/& cow_spacesize=4G/'  "$PROFILE"/syslinux/*.cfg 2>/dev/null || true

echo "==> Setting up services"
SYS="$PROFILE/airootfs/etc/systemd/system"
mkdir -p "$SYS/multi-user.target.wants" "$SYS/bluetooth.target.wants"

# Arch's live ISO uses a different network setup. Remove it so NetworkManager can take over.
find "$SYS" \( -name 'systemd-networkd*' -o -name 'iwd.service' \) -prune -exec rm -rf {} +

ln -sf /usr/lib/systemd/system/graphical.target       "$SYS/default.target"
ln -sf /usr/lib/systemd/system/sddm.service           "$SYS/display-manager.service"
ln -sf /usr/lib/systemd/system/NetworkManager.service "$SYS/multi-user.target.wants/NetworkManager.service"
ln -sf /usr/lib/systemd/system/bluetooth.service      "$SYS/bluetooth.target.wants/bluetooth.service"
ln -sf /usr/lib/systemd/system/vboxservice.service    "$SYS/multi-user.target.wants/vboxservice.service"
ln -sf /etc/systemd/system/fuzion-locale.service      "$SYS/multi-user.target.wants/fuzion-locale.service"

echo "==> Building the ISO (this takes a while)"
mkdir -p "$HERE/out"
mkarchiso -v -w "$WORKDIR" -o "$HERE/out" "$PROFILE"

echo "==> Done:"
ls -lh "$HERE/out"
