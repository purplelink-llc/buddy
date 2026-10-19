# Changelog

## 0.3.0

### Added
- Chats stopped by a dropped connection ("Can't reach the API server", "Connection lost mid-response", or the Mac going to sleep mid-response) now recover on their own. Buddy shows them with a no-connection badge, and when the network comes back (or the Mac wakes) it opens each one and presses Try again, or types "continue". At most three tries per drop.

### Fixed
- The countdown beside the notch no longer runs under the camera. It now reads "1h 14m", then "14:25" under an hour. The banner keeps the full timer.

## 0.2.1

### Changed
- Buddy is now a purple pup: a new app icon (a cartoon Lab/Chow mix) and a new notch character with short upright ears. He still glances while Claude works, hops when a session needs you, and smiles with his tongue out when it finishes.

## 0.2.0 (first public release)

### Added
- Click a session to open its exact Claude app chat, Terminal or iTerm2 tab, or VS Code/Cursor window.
- Chat titles from the Claude app instead of folder names.
- Click or swipe a row to clear it until something new happens in that session.
- A scrolling list after six sessions.
- Usage limits: a countdown to the reset, paused chats listed (including ones paused before Buddy ran), Continue now, and Auto (types "continue" a few minutes after the reset).
- Connect to Claude Code from the app, with a first-run banner. Disconnect from the right-click menu.
- An app icon.

### Changed
- The hook is a small native program (about 4 to 5 ms per event instead of 25 to 30 ms for a shell script) and trims large tool output before Buddy reads it.
- Needs-you opens the list for 20 seconds, then shows a badge. Finished sessions keep a green check until you look.
- Signed with a Developer ID, so the Accessibility permission survives updates.

### Fixed
- A session no longer stays "working" after you press Esc.
- Buddy no longer watches every mouse movement on the system; first clicks on the pill no longer fall through.
- Buddy no longer asks macOS for its login-item status on every redraw.

## 0.1.0
- First version: a notch companion that shows Claude Code sessions working, needing you, and finished.
