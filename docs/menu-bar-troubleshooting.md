# Missing menu-bar icon on macOS Tahoe

Just Aloud uses a standard `NSStatusItem` with the monochrome `waveform`
system symbol. Its autosave name is `JustAloudMenuBar`. macOS controls its
placement and template appearance. The app does not force screen coordinates
or reset your Command-drag position on launch.

If the icon is missing, first check **System Settings > Menu Bar > Allow in
the Menu Bar > Just Aloud**. Check both displays and whether the menu bar is
automatically hidden. A running process alone does not prove a visible icon.

## Enabled but still invisible

Tahoe can retain an incorrect association between a status item and another
application. If that other application's menu-bar permission is disabled,
Control Center may block Just Aloud even though Just Aloud itself is enabled.
This behavior has also been [reported by another menu-bar application](https://github.com/steipete/CodexBar/issues/1440).

A local investigation confirmed this combination:

- Just Aloud's own `trackedApplications` record was allowed.
- An unrelated disabled application's `menuItemLocations` also contained
  `space.exlumina.justaloud`.
- Control Center logged `Moving host to blocked list` for Just Aloud.
- Removing only the stale association, after backing up preferences, and
  restarting the user's preference service, Control Center, and Just Aloud
  restored the waveform on both displays.

This state lives in macOS-managed preferences, not Just Aloud's configuration.
Do not delete all Control Center preferences, change the bundle identifier,
reset Accessibility permission, or repeatedly recreate the status item to
work around it. Do not infer physical visibility from the status button's
proxy-window coordinates on Tahoe.

The app deliberately does not rewrite these private system preferences.
Any repair should be targeted, backed up, and preserve other applications'
allow states. After repair, take a screen capture, identify the waveform,
open its menu, and repeat the screen check after quitting and reopening.

## Accessibility is enabled but the shortcut is unavailable

Accessibility approval also checks the app's code-signing identity. An old
approval may not authorize the current build even when Settings shows an
enabled switch. The system log reports `Failed to match existing code
requirement` in this case. Apple describes this distinction in
[Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

Remove only Just Aloud's old entry from **Privacy & Security > Accessibility**,
then add **/Applications/Just Aloud.app** and enable it. Authenticate in macOS
when asked. The app silently watches for permission being granted; if macOS
requires a restart, quit and reopen Just Aloud. Never modify the TCC database
or disable macOS privacy protections to repair this. Keep the same Developer
ID signing identity for subsequent installed builds.
