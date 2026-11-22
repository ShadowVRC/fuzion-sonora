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
# fuzion-run: opens Windows programs (.exe and .msi) with no setup needed.
# Each program gets its own hidden Windows environment, created automatically.
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
PREFIX="$ROOT/prefixes/${SAFE}-${HASH}"
LOG="$ROOT/logs/${SAFE}-${HASH}.log"
mkdir -p "$ROOT/prefixes" "$ROOT/logs"

export WINEPREFIX="$PREFIX"
export WINEARCH=win64
export WINEDEBUG=-all

# First time: quietly create the Windows environment for this program
if [ ! -d "$PREFIX/drive_c" ]; then
  kdialog --passivepopup "Setting up Windows support for $NAME. This only happens once." 8 &
  if ! wineboot -u >>"$LOG" 2>&1; then
    kdialog --error "Fuzion Sonora could not set up Windows support for this program."
    exit 1
  fi
  wineserver -w
  {
    echo "source=$FILE"
    echo "created=$(date -Is)"
  } > "$PREFIX/fuzion.info"
fi

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

echo "==> Building the ISO (this takes a while)"
mkdir -p "$HERE/out"
mkarchiso -v -w "$WORKDIR" -o "$HERE/out" "$PROFILE"

echo "==> Done:"
ls -lh "$HERE/out"
