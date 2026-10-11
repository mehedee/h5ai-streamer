# Windows in-app updater plan

Status: planned. Desktop 3.0.2 ports library clearing and Home search changes only.
The current update script builds locally and installs a portable Windows copy.
It does not check a release feed or download a published app update.

## Expected behaviour

1. Add Check for Updates to Settings and the application menu.
2. Offer daily background checks while Myra runs, with a saved opt-out and last-check time.
3. Show the new version, release notes, download progress and errors.
4. Require confirmation before installation and relaunch.
5. Preserve the profile, credentials, index, configured download paths and prior installation.

## Implementation approach

1. Keep the existing portable ZIP distribution for Windows x64. Evaluate a maintained .NET
   updater against this packaging before selecting a dependency. Sparkle's macOS integration
   cannot be reused by the Avalonia Windows app.
2. Publish a Windows-specific signed manifest. Include version, minimum Windows version,
   architecture, immutable archive URL, archive hash, signature and release-notes URL.
   Do not reuse the macOS DMG feed as a Windows package feed.
3. Embed the trusted public key in the build. Verify the manifest and archive before extraction.
   Reject incompatible packages, invalid signatures and ZIP entries that escape the staging folder.
4. Download and extract to a temporary staging folder. Use a separate helper for installation:
   wait for Myra to exit, retain the previous installation, replace app files, then relaunch.
   Account for locked files, read-only installation folders, interrupted updates and rollback.
5. Keep profile data outside installation replacement. Do not remove or rewrite `%APPDATA%\Myra`
   or download folders. Future schema changes need their own backup and downgrade checks.
6. Prepare signed release assets locally. Enable published-feed checks only when the release
   endpoint and signed Windows assets exist. Publishing remains a separate release step.

## Acceptance checks

1. Exercise manual checks, daily scheduling, disabled checks and saved preferences with a local fixture feed.
2. Reject tampered feeds and archives, older versions, wrong architectures and unsafe ZIP paths.
3. Test cancelled downloads, offline hosts and interrupted installation without changing the active app.
4. Run old-to-new installation and rollback on Windows 10 and 11 using disposable app copies and profiles.
5. Verify source, download, personal-library and credential records remain available after relaunch.

Linux updater packaging and macOS updater hosting are outside this Windows plan.
