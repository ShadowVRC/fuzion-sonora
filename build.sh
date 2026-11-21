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
