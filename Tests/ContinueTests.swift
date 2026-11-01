import AppKit

// The auto-continue safety rules, each learned from an incident, checked against a fake Mac:
// nothing here reads the real screen, focuses a real app or posts a real key. Sleeps advance
// a fake clock, so a test that would take a minute on a real Mac takes no time.

/// A stand-in for the Mac and the Claude app as the continue path sees them. Keys reach the
/// app's focused element; a letter with Command is a shortcut (on 2026-10-25 a stuck Command
/// turned "continue" into Cmd-C, Cmd-O, ... and Cmd-U opened the Open panel), and a key from a
/// shared source picks up whatever modifiers are stuck; Return sends what the box holds and
/// the chat's hook reports it.
@MainActor
final class FakeMac {
    var front: String? = Jump.claudeApp
    var locked = false
    var idleSeconds: Double = 60
    var clock = ISO8601DateFormatter().date(from: "2027-01-16T01:50:00Z")!  // 8:50 pm in New York
    /// title → that chat's Prompt box (two titles = a split view).
    var chats: [String: AXUIElement] = [:]
    var text: [pid_t: String] = [:]
    var focused: AXUIElement?
    var focusTakes = true
    /// The chat's hook: called with the text a Return sent (nil = the hook is off).
    var hook: ((String) -> Void)?
    /// Modifiers the system's synthetic key state holds without a physical key down.
    var stuck: CGEventFlags = []
    /// Runs after every sleep (lock the screen, switch apps, type into the box...).
    var during: ((FakeMac) -> Void)?

    var posted: [KeyPress] = []
    var shortcuts: [KeyPress] = []
    var sent: [String] = []
    var pressed = 0
    var opened: [String] = []
    private var selectedAll = false

    func box(_ id: pid_t, title: String, text initial: String = "") -> AXUIElement {
        let el = AXUIElementCreateApplication(id)  // a distinct element, no app behind it, nothing asked of the system
        chats[title] = el
        text[id] = initial
        return el
    }

    func pid(_ el: AXUIElement) -> pid_t { var p: pid_t = 0; AXUIElementGetPid(el, &p); return p }
    func textIn(_ el: AXUIElement) -> String { text[pid(el)] ?? "" }
    var keyDowns: [KeyPress] { posted.filter(\.down) }
    var typed: String { String(keyDowns.compactMap(\.character)) }

    private func receive(_ press: KeyPress) {
        posted.append(press)
        guard press.down, !press.modifierOnly, !locked, front == Jump.claudeApp, let box = focused else { return }
        let flags = press.source == .privateState ? press.flags : press.flags.union(stuck)
        let id = pid(box)
        if flags.contains(.maskCommand) {
            if press.key == 0 { selectedAll = true } else { shortcuts.append(press) }
            return
        }
        switch press.key {
        case 51:  // Delete
            text[id] = selectedAll ? "" : String((text[id] ?? "").dropLast())
            selectedAll = false
        case 36:  // Return
            let message = text[id] ?? ""
            guard !message.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            sent.append(message)
            text[id] = ""
            hook?(message)
        default:
            if let c = press.character { text[id, default: ""].append(c) }
        }
    }

    var system: ContinueSystem {
        ContinueSystem(
            canType: { true },
            frontmostBundleID: { self.front },
            frontmostApplication: { nil },  // nothing real to put back in front
            screenLocked: { self.locked },
            secondsSinceTypingOrClicking: { self.idleSeconds },
            modifierFlags: { $0 == .hidSystemState ? self.stuck : [] },
            openChat: { self.opened.append($0) },
            raiseWindow: {},
            sendToTab: { _, _ in },
            prompt: { self.chats[$0] },
            focusedElement: { self.focused },
            value: { self.textIn($0) },
            focus: { el in if self.focusTakes { self.focused = el } },
            sendButton: { _ in nil },
            button: { _ in nil },
            press: { _ in self.pressed += 1 },
            post: { self.receive($0) },
            now: { self.clock },
            sleep: { duration in
                let (seconds, atto) = duration.components
                self.clock.addTimeInterval(Double(seconds) + Double(atto) / 1e18)
                self.during?(self)
                await Task.yield()
            }
        )
    }
}

@MainActor
func continueTests() async {
    let defaults = UserDefaults(suiteName: "buddy-continue-tests-\(UUID().uuidString)")!
    defaults.set(true, forKey: "autoTypeContinue")
    var fake = FakeMac()
    let store = Store(defaults: defaults, sound: { _ in }, now: { fake.clock })
    let continuer = Continuer(store: store)
    var serial = 0
    var id: String { "c\(serial)" }
    var boxID: pid_t { pid_t(90_000 + serial) }

    /// A fresh fake Mac and one chat paused by a limit (resets 9 pm), whose hook reports sends.
    func setUp(_ draft: String = "") -> AXUIElement {
        fake = FakeMac()
        Continuer.system = fake.system
        Continuer.unlockedAt = nil
        serial += 1
        let chat = id
        let host = "com.anthropic.claudefordesktop\tlocal_cont-\(chat)\t"
        store.apply([event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(chat)","prompt":"work"}"#, host: host, at: fake.clock),
                     event(#"{"hook_event_name":"StopFailure","session_id":"\#(chat)","error":"rate_limit","last_assistant_message":"You've hit your session limit · resets 9pm (America/New_York)"}"#, host: host, at: fake.clock)])
        fake.hook = { text in
            store.apply([event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(chat)","prompt":"\#(text)"}"#, host: host, at: fake.clock)])
        }
        return fake.box(boxID, title: "Night run", text: draft)
    }
    func continueChat() async -> String {
        await continuer.continueOpenChat(sessionID: "local_cont-\(id)", storeID: id, title: "Night run")
    }
    var paused: Bool { store.sessions[id]?.mood == .paused }
    func everyKeyReleased() -> Bool { fake.keyDowns.allSatisfy { d in fake.posted.contains { !$0.down && $0.key == d.key } } }

    // MARK: the normal case: types exactly "continue" into the chat's box and the hook confirms it
    var box = setUp()
    var outcome = await continueChat()
    expect(outcome == "sent" && fake.sent == ["continue"] && !paused, "a clean run sends continue, got \(outcome) \(fake.sent)")
    expect(fake.typed == "continue" && fake.shortcuts.isEmpty, "only the letters of continue, got \(fake.typed)")

    // MARK: 1. Nothing is typed unless Claude is in front and focus is this chat's own Prompt box
    box = setUp()
    fake.front = "com.apple.Safari"
    outcome = await continueChat()
    expect(outcome == "skipped: the Claude app is not in front" && fake.posted.isEmpty, "another app in front: no keys at all, got \(outcome)")

    box = setUp()
    fake.focusTakes = false
    fake.focused = fake.box(91_999, title: "Attach")  // the attach control kept focus (2026-10-25)
    outcome = await continueChat()
    expect(outcome == "skipped: could not put the cursor in the chat's message box" && fake.posted.isEmpty && fake.textIn(box) == "",
           "focus stays elsewhere: no keys, got \(outcome)")

    box = setUp()
    fake.during = { mac in if mac.typed == "c" { mac.front = "com.apple.Safari" } }  // you switch apps mid-word
    outcome = await continueChat()
    expect(outcome.hasPrefix("skipped") && fake.typed == "c" && fake.sent.isEmpty && paused,
           "switching apps after the first letter stops every later key, got \(outcome), typed \(fake.typed)")
    expect(everyKeyReleased(), "every key that went down came back up")

    box = setUp()
    fake.during = { mac in if mac.typed == "continue" { mac.front = "com.apple.Safari" } }  // gone just before Return
    outcome = await continueChat()
    expect(!fake.keyDowns.contains { $0.key == 36 } && fake.sent.isEmpty && paused, "no Return once Claude has left the front, got \(outcome)")

    // MARK: 2. A draft in the box is never sent or deleted
    box = setUp("half-written reply to the reviewer")
    outcome = await continueChat()
    expect(outcome == "skipped: the chat's message box has unsent text" && fake.keyDowns.isEmpty,
           "a draft: no key goes down, got \(outcome) \(fake.keyDowns.map(\.key))")
    expect(fake.textIn(box) == "half-written reply to the reviewer" && fake.sent.isEmpty && fake.pressed == 0 && paused,
           "the draft is untouched and unsent")

    box = setUp("cont")
    outcome = await continueChat()
    expect(outcome.hasPrefix("skipped") && fake.textIn(box) == "cont" && fake.keyDowns.isEmpty, "a draft that starts like continue is still yours")

    box = setUp("Continue")
    outcome = await continueChat()
    expect(outcome == "sent" && fake.sent == ["continue"], "a leftover continue from an earlier try is cleared and replaced, got \(outcome) \(fake.sent)")

    box = setUp()
    fake.during = { mac in if mac.typed == "continue", mac.text[boxID] == "continue" { mac.text[boxID] = "continue and also deploy" } }
    outcome = await continueChat()
    expect(fake.sent.isEmpty && !fake.keyDowns.contains { $0.key == 36 } && fake.textIn(box) == "continue and also deploy",
           "text you add while Buddy types is never sent, got \(outcome) \(fake.sent)")

    // MARK: 3. Every key comes from a private source with explicit flags; a stuck Command can't make a shortcut
    box = setUp("continue")
    fake.stuck = [.maskCommand]
    outcome = await continueChat()
    let typing = fake.posted.filter { !$0.modifierOnly && $0.key != 0 }
    expect(outcome == "sent" && fake.sent == ["continue"] && fake.shortcuts.isEmpty,
           "a stuck Command: still continue, never Cmd-U, got \(outcome) \(fake.shortcuts.map(\.key))")
    expect(!typing.isEmpty && typing.allSatisfy { $0.flags.isEmpty && $0.source == .privateState }, "letters, Delete and Return: no modifiers, private source")
    let withCommand = fake.posted.filter { $0.flags.contains(.maskCommand) }.map(\.key)
    expect(withCommand == [55, 0, 0], "Command only around Cmd-A, got \(withCommand)")
    let release = fake.posted.firstIndex { $0.key == 55 && !$0.down && $0.source == .hidSystemState }
    let firstLetter = fake.posted.firstIndex { $0.character != nil }
    expect(release != nil && firstLetter != nil && release! < firstLetter!, "the stuck Command is released before the first letter")
    // The real events, built but never posted. A private source gets its own state ID; the
    // shared ones (which carry other apps' modifiers) are combinedSessionState and hidSystemState.
    let shared = [CGEventSourceStateID.combinedSessionState, .hidSystemState].map { Int64($0.rawValue) }
    for press in [KeyPress(key: 8, down: true, character: "c"), KeyPress(key: 36, down: false)] {
        let made = press.event()
        let state = made?.getIntegerValueField(.eventSourceStateID)
        expect(made?.flags == [] && state != nil && !shared.contains(state!),
               "the CGEvent for key \(press.key) has empty flags from a private source, got flags \(made?.flags.rawValue ?? 0) state \(state ?? -9)")
    }
    let releaseEvent = KeyPress(key: 55, down: false, modifierOnly: true, source: .hidSystemState).event()
    expect(releaseEvent?.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue),
           "(the check can tell: a stuck-key release does use the shared state)")
    expect(KeyPress(key: 55, down: false, modifierOnly: true).event()?.type == .flagsChanged, "a modifier on its own is a flagsChanged event")

    // MARK: 4. "Sent" only when the chat's hook reports the new message
    box = setUp()
    fake.hook = nil  // the chat's hook is off: the text leaves the box but nothing reports it
    outcome = await continueChat()
    expect(outcome == "sent (not confirmed)" && paused, "no hook report: not a confirmed send, got \(outcome)")

    box = setUp()
    fake.hook = nil
    fake.during = { mac in if mac.sent.count == 1 { mac.text[boxID] = "continue" } }  // the Return didn't take
    outcome = await continueChat()
    expect(outcome == "skipped: sending was not confirmed" && paused, "text still in the box, no report: skipped, got \(outcome)")

    // MARK: 5. Locked: no typing, a skipped try doesn't count, and unlocking retries after the app settles
    var handed: [Session] = []
    store.onContinue = { sessions, manual in if !manual { handed += sessions } }
    box = setUp()
    fake.clock.addTimeInterval(11 * 60)  // 9:01 pm: the limit has reset and Auto is due
    store.runAutoContinue()
    let due = handed.filter { $0.id == id }
    expect(due.count == 1 && store.sessions[id]?.continueAttempts == 1, "Auto counts the try it starts")
    fake.locked = true
    await continuer.continueAll(due, manual: false)
    expect(fake.posted.isEmpty && fake.opened.isEmpty, "locked: no keys, and the chat isn't even opened")
    expect(store.sessions[id]?.continueSkipped == true && store.sessions[id]?.continueAttempts == 0,
           "the skipped try is handed back and doesn't count")
    handed = []
    fake.locked = false
    let unlocked = fake.clock
    await continuer.screenDidUnlock()
    expect(handed.contains { $0.id == id }, "unlocking retries the chat Auto couldn't reach")
    expect(fake.clock.timeIntervalSince(unlocked) > Continuer.settleAfterUnlock, "...after the app has had \(Continuer.settleAfterUnlock) s to redraw")
    store.onContinue = nil
    Continuer.unlockedAt = fake.clock.addingTimeInterval(-1)  // unlocked a second ago
    let waitStart = fake.clock
    let safe = await continuer.waitUntilSafeToType(manual: true)
    expect(safe && fake.clock.timeIntervalSince(waitStart) >= Continuer.settleAfterUnlock - 1,
           "a run right after unlocking waits out the settle time, waited \(fake.clock.timeIntervalSince(waitStart)) s")
    Continuer.unlockedAt = nil
    fake.locked = true
    let safeLocked = await continuer.waitUntilSafeToType(manual: true)
    expect(!safeLocked, "locked: not safe, even for Continue now")

    box = setUp()
    fake.during = { mac in if mac.typed == "co" { mac.locked = true } }  // the Mac locks mid-word
    outcome = await continueChat()
    expect(fake.typed == "co" && fake.sent.isEmpty && !fake.keyDowns.contains { $0.key == 36 } && everyKeyReleased(),
           "locking mid-word stops every later key, typed \(fake.typed)")

    // MARK: 6. Split view or the wrong chat in front: no typing
    box = setUp()
    let other = fake.box(92_000, title: "Other chat")
    fake.focusTakes = false
    fake.focused = other  // the other half of a split view holds focus
    outcome = await continueChat()
    expect(outcome.hasPrefix("skipped") && fake.posted.isEmpty && fake.textIn(other) == "", "split view: the other chat's box gets nothing, got \(outcome)")

    box = setUp()
    fake.chats["Night run"] = nil  // the app shows a different chat; this one's title isn't on screen
    fake.focused = fake.box(92_001, title: "Some other chat")
    outcome = await continueChat()
    expect(outcome == "skipped: no Prompt box appeared" && fake.posted.isEmpty, "wrong chat in front: nothing typed, got \(outcome)")

    box = setUp()
    let previous = fake.box(92_002, title: "Previous chat")
    var looks = 0
    var switching = fake.system
    switching.prompt = { _ in looks += 1; return looks % 2 == 0 ? box : previous }  // still switching chats
    Continuer.system = switching
    outcome = await continueChat()
    expect(outcome == "skipped: no Prompt box appeared" && fake.posted.isEmpty, "a box that isn't the same twice in a row is never used, got \(outcome)")

    Continuer.system = .live
}
