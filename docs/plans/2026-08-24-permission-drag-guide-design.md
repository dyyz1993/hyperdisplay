# Permission drag-guide design

## Goal

Make first-run macOS permissions discoverable without asking users to locate the
app through a file picker. The guide exposes the real `Hyperdisplay.app` bundle
as a drag source and points to the active System Settings privacy list.

## Flow

1. If Accessibility is missing, open its System Settings page and show a
   borderless, non-activating tray below that window. The app icon pulses and an
   animated upward arrow explains the drop direction. This permission becomes
   effective in the current process.
2. Once Accessibility is granted, apply the same guide to Screen Recording.
   Once granted, do not start capture in the existing process: show the restart
   state and relaunch normally so the fresh process receives the TCC grant.
3. With both permissions granted the guide is absent. The menu-bar command can
   reopen the next missing permission guide.

## Boundaries

The guide reads only window geometry from `CGWindowList`; it never reads screen
pixels, bypasses TCC, or touches the virtual-display / UDP data path. The app
bundle URL remains the sole drag payload.
