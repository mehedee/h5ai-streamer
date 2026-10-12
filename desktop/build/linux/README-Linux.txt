Myra 3.0.2 for Linux (x86-64)
============================

1. Install the system dependencies.
   Arch/Omarchy:  sudo pacman -S --needed aria2 libvlc vlc-plugins-base vlc-plugins-video-output vlc-plugin-ffmpeg vlc-plugin-matroska vlc-plugin-pulse xorg-xwayland libnotify
   Debian/Ubuntu: sudo apt install aria2 libvlc-dev vlc-plugin-base vlc-plugin-video-output
2. Run ./install.sh (installs for your user only; no root).
3. Start "Myra" from your app launcher, or run: myra

The package includes the .NET runtime. X11 and XWayland are supported.
Install the optional vlc package if you use "Open in external VLC".

Update: Close Myra, then run the new package's ./install.sh.
The installer keeps the previous app in ~/.local/share/myra.backup-<date>.<suffix>.
It preserves your existing profile, credentials and download paths.
To roll back, close Myra and replace ~/.local/share/myra with that backup.
If you set XDG_DATA_HOME, use that directory instead of ~/.local/share.

If upgrading from a differently named app, migrate before Myra's first start:
  python3 -I ./migrate-profile.py /path/to/old-profile /path/to/Myra --store-filename OLD_STORE.json
Use the actual old profile directory and JSON filename. The utility keeps the
original profile and refuses to overwrite an existing destination.

Features match the Windows 3.0.2 build: AI with OpenAI/Claude, fuzzy search,
subtitles, icon choices, confirmed Continue Watching clearing and Home search.
Apple Intelligence and Apple Shortcuts remain macOS-only.
In-app updates are currently macOS-only; Linux and Windows use install scripts.
REVISION.txt identifies the source revision used to build this package.

Data:      ~/.config/Myra (sources, settings, search index, resume points)
Downloads: ~/Downloads/Myra (change in Settings)
Remove:    ./uninstall.sh
