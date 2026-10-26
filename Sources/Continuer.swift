import AppKit
import ApplicationServices

/// Buddy's backup for Claude Code's own auto-continue: types "continue" into chats that
/// are still paused after a usage limit resets.
///
/// - Terminal and iTerm2 tabs get the text sent straight to the tab (no keyboard takeover).
/// - Claude app chats are opened with their deep link and typed into, which needs the
///   Accessibility permission. Buddy never types while the screen is locked (it would land
///   in the password field) or while you are typing, and puts you back where you were.
@MainActor
final class Continuer {
    static let message = "continue"
    /// Seconds without typing or clicking before the automatic run borrows the keyboard.
    static let quietSeconds: Double = 3

    private var running = false
    private let store: Store
    /// When the Mac was last unlocked: the Claude app needs a moment to redraw its chat
    /// before the Prompt box can be found (it failed straight after unlocking on 2026-10-22).
    static var unlockedAt: Date?
    static let settleAfterUnlock: TimeInterval = 5

    init(store: Store) {
        self.store = store
    }

    static var canType: Bool { AXIsProcessTrusted() }

    /// Shows macOS's Accessibility prompt (once) if Buddy is not allowed to type yet.
    static func askToType() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// `manual`: you pressed Continue now, so start at once. Otherwise (the timer after a
    /// reset) wait until you have stopped typing and clicking for a moment.
    /// Chats a dropped connection stopped: press the chat's Try again button when it has
    /// one, otherwise type "continue". Waits like the automatic run (never mid-typing).
    func retry(_ sessions: [Session]) {
        run(sessions, manual: false, tryAgainFirst: true)
    }

    func run(_ sessions: [Session], manual: Bool, tryAgainFirst: Bool = false) {
        guard !running else {
            // Busy with another run: these tries never happened, so Auto retries them later.
            if !manual { sessions.forEach { store.continueSkipped($0.id) } }
            return
        }
        running = true
        Log.note("continuing \(sessions.count) paused chats (\(manual ? "Continue now" : "automatic"))")
        Task {
            defer { running = false }
            let previous = NSWorkspace.shared.frontmostApplication
            var borrowedFocus = false
            var sent = 0
            for (index, session) in sessions.enumerated() {
                // Claude Code's own auto-continue may have resumed it in the meantime.
                guard let current = store.sessions[session.id], current.mood == .paused else { continue }
                store.continueStatus = "Continuing \(index + 1) of \(sessions.count)…"
                switch Jump.target(host: current.host, cwd: current.cwd) {
                case .terminalTab(let bundleID, let tty):
                    Self.sendToTab(bundleID: bundleID, tty: tty)
                    sent += 1
                case .desktopChat(let sessionID):
                    guard Self.canType else {
                        Log.note("no Accessibility permission, not typing into the Claude app")
                        store.continueStatus = "Allow Buddy in Accessibility to continue chats"
                        return
                    }
                    guard await waitUntilSafeToType(manual: manual) else {
                        // Locked (or you kept typing): no keystrokes now. Unlocking retries it.
                        Log.note("continue \(current.name): skipped: \(Self.screenLocked ? "screen locked" : "you were typing")")
                        if !manual { store.continueSkipped(session.id) }
                        continue
                    }
                    guard store.sessions[session.id]?.mood == .paused else { continue }
                    store.continueStatus = "Continuing \(index + 1) of \(sessions.count)…"
                    Jump.desktopChat(sessionID: sessionID).perform()
                    borrowedFocus = true
                    let outcome = await continueOpenChat(sessionID: sessionID, storeID: session.id, title: current.title,
                                                         tryAgainFirst: tryAgainFirst)
                    if outcome.hasPrefix("sent") { sent += 1 }
                    if outcome.hasPrefix("skipped"), !manual { store.continueSkipped(session.id) }
                    Log.note("continue \(current.name): \(outcome)")
                default:
                    continue
                }
            }
            if borrowedFocus, let previous, previous.bundleIdentifier != Jump.claudeApp {
                previous.activate()
            }
            Log.note("continued \(sent) of \(sessions.count) paused chats")
            store.continueStatus = "Continued \(sent) of \(sessions.count)"
            try? await Task.sleep(for: .seconds(8))
            if store.continueStatus == "Continued \(sent) of \(sessions.count)" { store.continueStatus = nil }
        }
    }

    /// Types into the chat the deep link just opened, with the Claude app in front. Keys go
    /// to whatever the app has focused, so Buddy types only after the app reports this chat's
    /// own message box as focused (on 2026-10-25 keys sent while it was in the background went
    /// to another chat's box in a split view, or to the attach control, opening the Open
    /// panel). A send counts only when the chat itself reports the new message.
    private func continueOpenChat(sessionID: String, storeID: String, title: String,
                                  tryAgainFirst: Bool = false) async -> String {
        try? await Task.sleep(for: .milliseconds(1200))  // let the app switch chats
        if tryAgainFirst {
            for _ in 0..<12 {  // the error card may take a moment to appear
                if let button = ClaudeUI.button(labelled: "Try again") {
                    ClaudeUI.press(button)
                    return "sent (pressed Try again)"
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        var prompt: AXUIElement?
        for attempt in 0..<60 {  // an old chat may take a few seconds to be ready
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Jump.claudeApp else {
                return "skipped: the Claude app is not in front"
            }
            if attempt == 24 {
                // Still nothing after about six seconds: open the chat again and bring its
                // window forward (after waking or unlocking, the first open can get lost).
                Jump.desktopChat(sessionID: sessionID).perform()
                ClaudeUI.raiseWindow()
                try? await Task.sleep(for: .milliseconds(1200))
            }
            // This chat's box (the one in the pane showing its title), the same element twice
            // in a row, so a box from the chat that was open before the switch is never used.
            if let found = ClaudeUI.prompt(inChatTitled: title) {
                try? await Task.sleep(for: .milliseconds(300))
                if let again = ClaudeUI.prompt(inChatTitled: title), CFEqual(found, again) { prompt = again; break }
                continue
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let prompt else { return "skipped: no Prompt box appeared" }
        guard !Self.screenLocked else { return "skipped: screen locked" }
        guard await Self.putCursor(in: prompt) else { return "skipped: could not put the cursor in the chat's message box" }
        Self.releaseStuckModifiers()
        if let refusal = await Self.makeRoom(in: prompt) { return refusal }
        // One letter first: if it doesn't show up in the box, stop before any other key could
        // act as a shortcut somewhere else.
        await Self.typeText(String(Self.message.prefix(1)))
        try? await Task.sleep(for: .milliseconds(250))
        guard ClaudeUI.isFocused(prompt), ClaudeUI.value(of: prompt).hasPrefix(String(Self.message.prefix(1))) else {
            return "skipped: keys did not reach the chat's message box"
        }
        await Self.typeText(String(Self.message.dropFirst()))
        try? await Task.sleep(for: .milliseconds(400))  // let the box register the text
        guard ClaudeUI.isFocused(prompt), ClaudeUI.value(of: prompt).contains(Self.message) else {
            return "skipped: the text did not land in the chat's message box"
        }
        Self.pressReturn()
        if await sendConfirmed(storeID) { return "sent" }
        if ClaudeUI.value(of: prompt).contains(Self.message), let send = ClaudeUI.sendButton(near: prompt) {
            ClaudeUI.press(send)
            if await sendConfirmed(storeID) { return "sent with the Send button" }
        }
        // The text left the box but the chat never reported it (its hook may be off): count it
        // as a try, so Auto doesn't keep typing "continue" into a chat that already got one.
        if !ClaudeUI.value(of: prompt).contains(Self.message) { return "sent (not confirmed)" }
        return "skipped: sending was not confirmed"
    }

    /// The chat reports a new message through its hook (Buddy then no longer has it as
    /// paused). Waits up to eight seconds.
    private func sendConfirmed(_ storeID: String) async -> Bool {
        for _ in 0..<32 {
            try? await Task.sleep(for: .milliseconds(250))
            if store.sessions[storeID]?.mood != .paused { return true }
        }
        return false
    }

    /// Focuses the box and waits until the app itself reports it as focused.
    private static func putCursor(in prompt: AXUIElement) async -> Bool {
        for _ in 0..<12 {
            ClaudeUI.focus(prompt)
            try? await Task.sleep(for: .milliseconds(150))
            if ClaudeUI.isFocused(prompt) { return true }
        }
        return false
    }

    /// True once it is safe to type: the screen is unlocked (and has been for a few seconds)
    /// and, for the automatic run, you have paused typing and clicking (mouse movement does
    /// not count). A locked screen returns false at once instead of holding the run open for
    /// hours; unlocking the Mac retries it. Waits at most ten minutes for a typing pause.
    private func waitUntilSafeToType(manual: Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(10 * 60)
        while Date() < deadline {
            if Self.screenLocked {
                store.continueStatus = "Waiting for you to unlock the Mac…"
                return false
            }
            if let unlocked = Self.unlockedAt, Date().timeIntervalSince(unlocked) < Self.settleAfterUnlock {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            if manual || Self.secondsSinceTypingOrClicking >= Self.quietSeconds { return true }
            store.continueStatus = "Waiting for you to stop typing…"
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    static var screenLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return (info["CGSSessionScreenIsLocked"] as? Bool) == true || (info["kCGSSessionOnConsoleKey"] as? Bool) == false
    }

    private static var secondsSinceTypingOrClicking: Double {
        [CGEventType.keyDown, .leftMouseDown, .rightMouseDown]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }

    /// ANSI key codes for the letters Buddy types, so apps that read the key (not just the
    /// character) see the right one.
    private static let keyCodes: [Character: CGKeyCode] = [
        "c": 8, "o": 31, "n": 45, "t": 17, "i": 34, "u": 32, "e": 14,
    ]

    /// Types `text` into the frontmost app, one key at a time like a person would.
    /// Each key carries exactly the modifiers given (none, for typing), from a private event
    /// source. A key event made from the shared system source inherits whatever modifiers
    /// that state holds, and on 2026-10-25 it held a stuck Command: "continue" became Cmd-C,
    /// Cmd-O, Cmd-N... and Cmd-U opened the Open panel.
    private static func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags = [], character: Character? = nil) {
        let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: key, keyDown: down)
        if let character {
            var units = Array(String(character).utf16)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        }
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    /// Releases modifiers the system's synthetic key state holds down while the physical
    /// keyboard doesn't (left there by some app's posted shortcut), so they can't leak into
    /// anything typed later. Physical keys you are holding are left alone.
    static func releaseStuckModifiers() {
        let synthetic = CGEventSource.flagsState(.hidSystemState)
        let physical = CGEventSource.flagsState(.combinedSessionState)
        for (flag, key) in [(CGEventFlags.maskCommand, CGKeyCode(55)), (.maskShift, 56), (.maskAlternate, 58), (.maskControl, 59)]
            where synthetic.contains(flag) && !physical.contains(flag) {
            let up = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: key, keyDown: false)
            up?.type = .flagsChanged
            up?.flags = []
            up?.post(tap: .cghidEventTap)
            Log.note("released a stuck modifier key (\(key)) before typing")
        }
    }

    private static func typeText(_ text: String) async {
        for character in text {
            for down in [true, false] { post(keyCodes[character] ?? 0, down: down, character: character) }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Before typing: an empty box is fine; a leftover "continue" from an earlier try is
    /// cleared; anything else is your unsent text, which Buddy neither sends nor deletes, so
    /// it leaves the chat alone (a skipped try, retried later). Returns that refusal, or nil.
    /// Only called once the box is confirmed focused, so the clear can't reach anything else.
    private static func makeRoom(in prompt: AXUIElement) async -> String? {
        let draft = ClaudeUI.value(of: prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return nil }
        guard draft.lowercased() == message else { return "skipped: the chat's message box has unsent text" }
        guard ClaudeUI.isFocused(prompt) else { return "skipped: could not put the cursor in the chat's message box" }
        // Cmd-A with Command pressed and released around it (so it can't stay stuck), then Delete.
        let commandDown = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: 55, keyDown: true)
        commandDown?.type = .flagsChanged
        commandDown?.flags = .maskCommand
        commandDown?.post(tap: .cghidEventTap)
        for down in [true, false] { post(0, down: down, flags: .maskCommand) }
        let commandUp = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: 55, keyDown: false)
        commandUp?.type = .flagsChanged
        commandUp?.flags = []
        commandUp?.post(tap: .cghidEventTap)
        for down in [true, false] { post(51, down: down) }
        try? await Task.sleep(for: .milliseconds(300))
        return ClaudeUI.value(of: prompt).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : "skipped: could not clear an earlier \"continue\""
    }

    private static func pressReturn() {
        for down in [true, false] { post(36, down: down) }
    }

    /// Sends "continue" + Return to the Terminal or iTerm2 tab on `tty` (validated by Jump).
    private static func sendToTab(bundleID: String, tty: String) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else { return }
        let device = "/dev/\(tty)"
        let source: String
        if bundleID == Jump.terminal {
            source = """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(device)" then
                            do script "\(message)" in t
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        } else {
            source = """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(device)" then
                                tell s to write text "\(message)"
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
        }
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { Log.note("could not send continue to the terminal tab: \(error)") }
    }
}

/// Reads the Claude app's interface through the Accessibility API: its message box (an
/// AXTextArea labelled "Prompt"), its Send button, and the Try again button of a chat whose
/// connection dropped. The only value read is the Prompt box's, to see whether "continue"
/// was sent.
@MainActor
enum ClaudeUI {
    static func prompt() -> AXUIElement? {
        if let app = app(), let focused = element(app, kAXFocusedUIElementAttribute), isPrompt(focused) {
            return focused
        }
        return search { isPrompt($0) }
    }

    /// The message box of the chat titled `title`: found from the chat's own title button,
    /// climbing to the nearest pane that holds a box, so a chat open beside it (split view)
    /// is never used. With no title, only a window with exactly one box qualifies.
    static func prompt(inChatTitled title: String) -> AXUIElement? {
        let suffix = ", rename session"
        guard !title.isEmpty else {
            let boxes = all(isPrompt)
            return boxes.count == 1 ? boxes.first : nil
        }
        guard let titleButton = search({ el in
            string(el, kAXRoleAttribute) == kAXButtonRole as String && string(el, kAXDescriptionAttribute) == title + suffix
        }) else { return nil }
        var node: AXUIElement? = titleButton
        for _ in 0..<20 {
            guard let current = node else { break }
            if let box = first(in: current, isPrompt) { return box }
            node = element(current, kAXParentAttribute)
        }
        return nil
    }

    /// True when the Claude app reports `el` as its focused element.
    static func isFocused(_ el: AXUIElement) -> Bool {
        guard let app = app(), let focused = element(app, kAXFocusedUIElementAttribute) else { return false }
        return CFEqual(focused, el)
    }

    /// The "Send" button in the same pane as the box (exactly "Send": not "Send feedback").
    static func sendButton(near prompt: AXUIElement) -> AXUIElement? {
        var node: AXUIElement? = prompt
        for _ in 0..<8 {
            guard let current = node else { break }
            if let send = first(in: current, { el in
                string(el, kAXRoleAttribute) == kAXButtonRole as String
                    && (string(el, kAXDescriptionAttribute) == "Send" || string(el, kAXTitleAttribute) == "Send")
            }) { return send }
            node = element(current, kAXParentAttribute)
        }
        return nil
    }

    /// Breadth-first under `root`, bounded.
    private static func first(in root: AXUIElement, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let el = queue.removeFirst()
            visited += 1
            if match(el) { return el }
            queue += attribute(el, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        return nil
    }

    /// Every match in the app's windows, bounded.
    private static func all(_ match: (AXUIElement) -> Bool) -> [AXUIElement] {
        guard let app = app() else { return [] }
        var queue = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var found: [AXUIElement] = []
        var visited = 0
        while !queue.isEmpty, visited < 8000 {
            let el = queue.removeFirst()
            visited += 1
            if match(el) { found.append(el) }
            queue += attribute(el, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        return found
    }

    /// Brings the Claude app's main window forward.
    static func raiseWindow() {
        guard let app = app(), let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement],
              let window = windows.first else { return }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        NSRunningApplication.runningApplications(withBundleIdentifier: Jump.claudeApp).first?.activate()
    }

    /// The first button whose title or description contains `text` (case-insensitive).
    static func button(labelled text: String) -> AXUIElement? {
        search { el in
            guard string(el, kAXRoleAttribute) == kAXButtonRole as String else { return false }
            let label = string(el, kAXDescriptionAttribute) + " " + string(el, kAXTitleAttribute)
            return label.range(of: text, options: .caseInsensitive) != nil
        }
    }

    static func value(of el: AXUIElement) -> String { string(el, kAXValueAttribute) }

    static func focus(_ el: AXUIElement) {
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    static func press(_ el: AXUIElement) {
        AXUIElementPerformAction(el, kAXPressAction as CFString)
    }

    private static func isPrompt(_ el: AXUIElement) -> Bool {
        string(el, kAXRoleAttribute) == kAXTextAreaRole as String && string(el, kAXDescriptionAttribute) == "Prompt"
    }

    private static func app() -> AXUIElement? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Jump.claudeApp).first?
            .processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // The Claude app is Electron: its chat (Prompt box, buttons) is in the tree only once an
        // assistive client asks for it, and a relaunch or update forgets that. Ask every time;
        // it is one cheap call, and the tree fills in within a second.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return app
    }

    /// Breadth-first through the front window, bounded (the app's tree is a few hundred nodes).
    /// Just after unlocking there can be no focused window yet; with a single window, that one
    /// is the chat.
    private static func search(_ match: (AXUIElement) -> Bool) -> AXUIElement? {
        guard let app = app() else { return nil }
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let window = element(app, kAXFocusedWindowAttribute) ?? (windows.count == 1 ? windows.first : nil) else { return nil }
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 5000 {
            let (el, depth) = queue.removeFirst()
            visited += 1
            if match(el) { return el }
            guard depth < 50, let children = attribute(el, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            queue += children.map { ($0, depth + 1) }
        }
        return nil
    }

    private static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    private static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(el, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String {
        attribute(el, name) as? String ?? ""
    }
}
