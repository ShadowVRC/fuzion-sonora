# Fuzion Sonora

A Windows-replacement OS built on Arch Linux + KDE Plasma, with Windows apps and games
(Wine/Proton) built in.

## How the build works
1. You change files in this project.
2. GitHub automatically builds a new ISO (a bootable OS image) in the cloud.
3. You download the ISO from the **Actions** tab and test it in VirtualBox.

## Files
- `packages.txt` - the list of software included in the OS
- `overlay/` - config files copied into the OS (login, users, etc.)
- `build.sh` - the build script
- `.github/workflows/build.yml` - tells GitHub how to run the build
