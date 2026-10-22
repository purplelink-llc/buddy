# Changelog

## 0.8.0

### Fixed
- Auto no longer gives up on chats it never reached. If the Mac is locked when a limit resets, Buddy doesn't type (it would land in the password field) and tries again the moment you unlock, instead of holding the run open until morning and losing its retries.
- Tries that never reach a chat (locked screen, no message box, another run still busy) don't count against Auto's three.
- Right after you unlock, Buddy waits a few seconds for the Claude app to redraw, and if a chat's message box still doesn't appear it opens the chat again and brings the window forward. On 2026-10-22 every try right after unlocking ended with "no Prompt box appeared".
- Buddy's log no longer repeats the same exact-usage problem every three minutes.

### Added
- **Keep the Mac awake until they continue** (Settings → Usage limits, off by default). While Auto has chats waiting for a limit to reset, Buddy keeps the display from sleeping so the Mac doesn't lock, and lets it sleep again once they've continued. The Mac stays unlocked while you're away, so leave it off if that matters where you work. Closing the lid or locking by hand still stops Buddy until you unlock.

## 0.7.0

### Added
- A countdown just right of the notch to your next reset ("2h 19m", then "14:25" in the last hour). It counts to the session window's reset, or, in purple, to the usage limit that has chats paused. The status badge (needs you, finished, working) stays at the far right.

### Changed
- While a limit has chats paused, the right-hand badge shows an hourglass, since the countdown now sits beside the notch.

## 0.6.0

### Added
- With exact usage on, Settings shows which account Claude Code is signed in with (email and organization), so a wrong account is easy to spot. **Change** next to it offers **Switch Account…** (signs out, then opens Terminal with `claude auth login` so the browser asks which account to use) and **Sign Out…** (runs `claude auth logout` after you confirm).

### Fixed
- When macOS refuses or you dismiss the keychain prompt, Buddy now says so ("turn exact usage off and on, then choose Always Allow") instead of reporting that no sign-in was found.

### Note
- Buddy has no account of its own: it uses Claude Code's sign-in. Signing out from Buddy also signs out `claude` in Terminal on that Mac. The Claude app keeps its own sign-in.

## 0.5.1

### Fixed
- Auto, **Continue now** and connection retries work again after the Claude app restarts or updates. The Claude app stopped showing its message box to Buddy until something asked for it, so every try ended with "no Prompt box appeared". Buddy now asks for it each time.

### Added
- When exact usage can't find or use Claude Code's sign-in, Settings shows a **Sign In…** button next to the message. It opens Terminal and runs `claude auth login`, which finishes in your default browser; Buddy picks up the sign-in within a few seconds.

## 0.5.0

### Added
- Session usage, always on: beside the character Buddy shows how much of your 5-hour session window you have used and when it resets ("≈64%" over "2:20"). It turns orange at 70% and red at 90%. The open list starts with a usage meter.
- Usage is estimated from the token counts in your chats on this Mac (marked "≈"), calibrated on your recent session limits. Turn on **Exact usage from Anthropic** in Settings for exact session and weekly numbers; Buddy then reads Claude Code's sign-in from your keychain and asks Anthropic every few minutes.
- Automatic updates through Sparkle. Buddy checks once a day and installs signed, notarized updates. **Check for Updates…** in Settings now checks right away, and **Check for updates automatically** turns the daily check off.

### Changed
- Buddy now uses the network for the daily update check (and for exact usage, if you turn it on). Before 0.5.0 it made no network connections.
- Once Buddy knows your usage, the pill stays beside the notch even when no chat is active, and it is a little wider to fit the numbers.

## 0.4.0

### Added
- A small Settings window: right-click Buddy, then **Settings…**. It has open at login, separate sounds for chats that need you and chats that finish, Auto, connection retries (now switchable), the Claude Code connection, whether Accessibility is allowed, the version, **Check for Updates…** (opens the releases page in your browser; Buddy itself still makes no network connections) and **Show Log**.

### Changed
- The right-click menu is now Settings…, Clear Finished Sessions and Quit Buddy. If you had turned Sounds off, both sounds start off.

## 0.3.2

### Fixed
- The list always shows chats that need you (orange) first, then finished chats waiting on your reply (green), then working ones (blue). Hovering the notch used to drop finished chats below working ones.

## 0.3.1

### Fixed
- Auto now continues each paused chat one minute after its own limit resets. Chats paused together can reset at different times, and Auto used to wait for the latest reset (and six more minutes) before continuing any of them.
- Auto tries again if a chat is still paused three minutes later (at most three tries), and leaves alone chats whose limit reset more than 12 hours ago.
- The countdown shows the next reset.

### Added
- Buddy keeps a small log at `~/Library/Logs/Buddy/buddy.log`.

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
