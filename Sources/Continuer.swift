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
    func run(_ sessions: [Session], manual: Bool) {
        guard !running else { return }
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
                    guard await waitUntilSafeToType(manual: manual) else { continue }
                    guard store.sessions[session.id]?.mood == .paused else { continue }
                    store.continueStatus = "Continuing \(index + 1) of \(sessions.count)…"
                    Jump.desktopChat(sessionID: sessionID).perform()
                    borrowedFocus = true
                    let outcome = await continueOpenChat()
                    if outcome.hasPrefix("sent") { sent += 1 }
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

    /// Types into the chat the deep link just opened: waits for its Prompt box, focuses it,
    /// types, presses Return, and clicks Send if the text is still sitting there.
    private func continueOpenChat() async -> String {
        try? await Task.sleep(for: .milliseconds(1200))  // let the app switch chats
        var prompt: AXUIElement?
        for _ in 0..<40 {  // an old chat may take a few seconds to be ready
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Jump.claudeApp else {
                return "skipped: the Claude app is not in front"
            }
            // Accept the box only once it is the same element twice in a row, so a box from
            // the chat that was open before the switch is not typed into.
            if let found = ClaudeUI.prompt() {
                try? await Task.sleep(for: .milliseconds(300))
                if let again = ClaudeUI.prompt(), CFEqual(found, again) { prompt = again; break }
                continue
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let prompt else { return "skipped: no Prompt box appeared" }
        guard !Self.screenLocked else { return "skipped: screen locked" }
        ClaudeUI.focus(prompt)
        try? await Task.sleep(for: .milliseconds(200))
        await Self.typeText(Self.message)
        try? await Task.sleep(for: .milliseconds(400))  // let the box register the text
        Self.pressReturn()
        try? await Task.sleep(for: .milliseconds(1200))
        guard ClaudeUI.value(of: prompt).contains(Self.message) else { return "sent" }
        guard let send = ClaudeUI.sendButton() else { return "typed, but Return did not send and no Send button found" }
        ClaudeUI.press(send)
        try? await Task.sleep(for: .milliseconds(800))
        return ClaudeUI.value(of: prompt).contains(Self.message) ? "typed, but not sent" : "sent with the Send button"
    }

    /// Waits (up to 12 hours) for an unlocked screen and, for the automatic run, a pause in
    /// your typing and clicking (mouse movement does not count).
    private func waitUntilSafeToType(manual: Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(12 * 3600)
        while Date() < deadline {
            let locked = Self.screenLocked
            if !locked, manual || Self.secondsSinceTypingOrClicking >= Self.quietSeconds { return true }
            store.continueStatus = locked ? "Waiting for you to unlock the Mac…" : "Waiting for you to stop typing…"
            try? await Task.sleep(for: .seconds(locked ? 15 : 1))
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
    private static func typeText(_ text: String) async {
        let source = CGEventSource(stateID: .hidSystemState)
        for character in text {
            var units = Array(String(character).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: keyCodes[character] ?? 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                event?.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private static func pressReturn() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.post(tap: .cghidEventTap)
        }
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
/// AXTextArea labelled "Prompt") and Send button. Only these two are touched; the only
/// value read is the Prompt box's, to see whether "continue" was sent.
@MainActor
enum ClaudeUI {
    static func prompt() -> AXUIElement? {
        if let app = app(), let focused = element(app, kAXFocusedUIElementAttribute), isPrompt(focused) {
            return focused
        }
        return search { isPrompt($0) }
    }

    static func sendButton() -> AXUIElement? {
        search { el in
            guard string(el, kAXRoleAttribute) == kAXButtonRole as String else { return false }
            let label = string(el, kAXDescriptionAttribute) + " " + string(el, kAXTitleAttribute)
            return label.range(of: "send", options: .caseInsensitive) != nil
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
        return AXUIElementCreateApplication(pid)
    }

    /// Breadth-first through the front window, bounded (the app's tree is a few hundred nodes).
    private static func search(_ match: (AXUIElement) -> Bool) -> AXUIElement? {
        guard let app = app(), let window = element(app, kAXFocusedWindowAttribute) else { return nil }
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
