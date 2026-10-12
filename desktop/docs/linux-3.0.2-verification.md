# Linux 3.0.2 verification

Checked on 2026-10-12 with Ubuntu 22.04 under WSL, .NET 10.0.12 and an Xvfb X11 display.
Linux source starts from Windows 3.0.2 commit `7b9ad5a`. The shared library, AI, search,
subtitle and progress-clearing code is included in the Linux build.

| Check | Result |
| --- | --- |
| Core unit tests | 281 passed |
| Profile migration and Linux installer tests | 12 passed |
| Shared UI and integration checks | 211 passed |
| Native X11 video and fullscreen pointer checks | 3 passed |

Integration checks used isolated profiles, a local fixture server, real aria2 1.36.0 and
real VLC 3.0.16. Cloud AI requests used a fake provider. Native checks confirmed that VLC
displayed frames on the embedded X11 surface. They also checked that fullscreen controls
hide during inactivity and return after pointer movement over video.

Stream inspection previously crashed in VLC's native event manager. A small isolated parse
program also failed to exit. Yielding after `Media.Parse` moves inspection and disposal out
of the callback. The isolated program then exited normally, and the full inspection and
playback checks passed. No dependency versions were changed.

The expanded checks also corrected existing fixture errors: Offline Library included earlier
downloads, fullscreen transition checks used a live view instead of a simulated host, and a
60-second seek used a three-second episode. Command-line player events are now captured.

An exploratory test rapidly removed and reattached the same native video view. Frame output
did not recover on this harness. The current app keeps each player view in its original host;
this operation is outside the supported-flow checks and remains unresolved.

Arch/Omarchy, Hyprland/XWayland window-manager transitions, hardware decoding, physical audio
output and native Windows/macOS playback were not checked in this run. Apple Intelligence,
Apple Shortcuts and the macOS Sparkle updater remain platform-specific.

The Linux archive contains a self-contained runtime, install/uninstall scripts, the profile
migration utility and a source revision marker. Its accompanying SHA-256 file checks archive
integrity. The installer retains previous app directories and leaves personal profiles intact.
