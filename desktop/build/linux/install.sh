#!/usr/bin/env bash
# Installs Myra for the current user only (no root):
#   ~/.local/share/myra           the app
#   ~/.local/bin/myra             command-line launcher
#   ~/.local/share/applications    menu entry (app launchers such as Walker, GNOME, KDE)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
target="$data/myra"

if [ ! -x "$here/app/Myra" ] || [ ! -f "$here/myra.png" ]; then
  echo "Incomplete package: app/Myra and myra.png are required. Existing install kept." >&2
  exit 1
fi
if [ -L "$target" ]; then
  echo "The install directory is a symbolic link. Existing install kept: $target" >&2
  exit 1
fi
if [ -e "$target" ] && [ ! -d "$target" ]; then
  echo "The install path is not a directory. Existing install kept: $target" >&2
  exit 1
fi
for executable in /proc/[0-9]*/exe; do
  if [ "$(readlink "$executable" 2>/dev/null || true)" = "$target/Myra" ]; then
    echo "Close Myra before updating. Existing install kept." >&2
    exit 1
  fi
done

mkdir -p "$data" "$HOME/.local/bin" "$data/applications" "$data/icons/hicolor/256x256/apps"
stage="$(mktemp -d "$data/.myra-install.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
cp -a "$here/app/." "$stage/"

backup=""
if [ -d "$target" ]; then
  backup="$(mktemp -d "$target.backup-$(date +%Y%m%d-%H%M%S).XXXXXX")"
  mv -T -- "$target" "$backup"
fi
if ! mv -T -- "$stage" "$target"; then
  if [ -n "$backup" ]; then mv -T -- "$backup" "$target"; fi
  exit 1
fi
cp "$here/myra.png" "$data/icons/hicolor/256x256/apps/myra.png"

printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$target/Myra" > "$HOME/.local/bin/myra"
chmod +x "$HOME/.local/bin/myra"

# Desktop Entry values and quoted Exec arguments have separate escaping rules.
desktop_target="${target//\\/\\\\}"
desktop_target="${desktop_target//\"/\\\"}"
desktop_target="${desktop_target//\$/\\\$}"
desktop_target="${desktop_target//\`/\\\`}"
desktop_target="${desktop_target//\\/\\\\}"
desktop_target="${desktop_target//%/%%}"
cat > "$data/applications/myra.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Myra
GenericName=Media Browser and Downloader
Comment=Browse, stream and download from h5ai, Apache and nginx directories
Exec="$desktop_target/Myra" %u
Icon=myra
Terminal=false
Categories=AudioVideo;Video;Player;
MimeType=video/mp4;video/x-matroska;video/webm;video/quicktime;video/x-msvideo;video/mp2t;
StartupWMClass=Myra
DESKTOP
command -v update-desktop-database >/dev/null && update-desktop-database "$data/applications" >/dev/null 2>&1 || true

echo "Installed. Start Myra from your app launcher, or run: myra"
if [ -n "$backup" ]; then echo "Previous app kept in: $backup"; fi
echo "Sources, history, credentials and download paths are kept in your existing profile."
missing=()
command -v aria2c >/dev/null || missing+=("aria2 (downloads)")
# Read the whole ldconfig output: grep -q can give the producer SIGPIPE with pipefail.
ldconfig -p 2>/dev/null | grep 'libvlc\.so' >/dev/null || [ -e /usr/lib/libvlc.so.5 ] || missing+=("libVLC (playback)")
if [ ${#missing[@]} -gt 0 ]; then
  echo
  echo "Still needed: ${missing[*]}"
  echo "  Arch/Omarchy:  sudo pacman -S --needed aria2 libvlc vlc-plugins-base vlc-plugins-video-output vlc-plugin-ffmpeg vlc-plugin-matroska vlc-plugin-pulse xorg-xwayland libnotify"
  echo "  Debian/Ubuntu: sudo apt install aria2 libvlc-dev vlc-plugin-base vlc-plugin-video-output"
  echo "  Fedora:        sudo dnf install aria2 vlc-libs vlc-plugins-base  (RPM Fusion)"
fi
