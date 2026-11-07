import Foundation

// Logic tests for Buddy. Run with ./build.sh test, which points HOME at a throwaway folder.
// Nothing here opens windows, plays sounds, switches apps or posts keys: sounds, the clock and
// the Mac (ContinueSystem) are injected, and Jump is only asked for its target, never performed.

var failures = 0
var checks = 0
func expect(_ ok: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    checks += 1
    if !ok() { failures += 1; print("FAIL line \(line): \(what)") }
}

let home = NSHomeDirectory()
guard home.contains("buddy-tests") else {
    print("refusing to run: HOME is not a throwaway folder (\(home)); use ./build.sh test")
    exit(2)
}
let scratch = URL(fileURLWithPath: home).appendingPathComponent("scratch", isDirectory: true)
try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

func event(_ json: String, host: String = "com.apple.Terminal\t\tttys004", at date: Date) -> HookEvent {
    HookEvent(data: Data((host + "\n" + json).utf8), date: date)!
}

MainActor.assumeIsolated {
    // MARK: wording
    expect(Store.describe("Bash", ["command": "npm test", "description": "Run the test suite"]) == "Run the test suite", "bash description")
    expect(Store.describe("Bash", ["command": "ls -la"]) == "Running ls -la", "bash command")
    expect(Store.describe("Edit", ["file_path": "/a/b/View.swift"]) == "Editing View.swift", "edit")
    expect(Store.describe("mcp__notion__search_pages", [:]) == "Using search pages", "mcp tool")
    expect(Store.oneLine(Store.withoutTags("<system-reminder>\nx\n</system-reminder>  fix it"), 60) == "fix it", "strip tags")
    expect(Store.project("/Users/me/Code/Acme") == "Acme", "plain project")
    expect(Store.project("/Users/me/Code/Acme/.claude/worktrees/login-fix") == "Acme › login-fix", "app worktree")
    expect(Store.project("/Users/me/_worktrees/Widgets/refcheck/src") == "Widgets › refcheck", "_worktrees")
    expect(Store.shortCountdown(4465) == "1h 14m" && Store.shortCountdown(3600) == "1h 0m", "hours and minutes")
    expect(Store.shortCountdown(865) == "14:25" && Store.shortCountdown(59.2) == "1:00" && Store.shortCountdown(-3) == "0:00",
           "minutes and seconds under an hour, got \(Store.shortCountdown(865)) \(Store.shortCountdown(59.2))")
    expect(Store.duration(42) == "42s" && Store.duration(192) == "3m 12s" && Store.duration(3900) == "1h 5m", "durations")

    // MARK: header
    let h = event(#"{"session_id":"A"}"#, host: "com.anthropic.claudefordesktop\tlocal_abc-123\t", at: Date())
    expect(h.host == Host(bundleID: "com.anthropic.claudefordesktop", desktopSessionID: "local_abc-123", tty: ""), "header fields")

    // MARK: a turn: working → needs you → answered → finished → seen
    var clock = Date()
    var played: [String] = []
    let defaults = UserDefaults(suiteName: "buddy-tests-\(UUID().uuidString)")!
    let store = Store(defaults: defaults, sound: { played.append($0) }, now: { clock })

    store.apply([event(#"{"hook_event_name":"UserPromptSubmit","session_id":"A","cwd":"/p/Acme","prompt":"fix login","transcript_path":"/t.jsonl"}"#, at: clock)])
    var a = store.sessions["A"]!
    expect(a.mood == .working && a.prompt == "fix login" && a.turnStarted == clock, "prompt starts a turn")
    expect(a.transcriptPath == "/t.jsonl" && a.host.tty == "ttys004", "remembers transcript and tty")
    expect(store.hasNews && store.peek == nil, "working shows the pill without opening it")

    store.apply([event(#"{"hook_event_name":"PermissionRequest","session_id":"A","tool_name":"Bash","tool_input":{"command":"git push","description":"Push the fix"}}"#, at: clock)])
    store.apply([event(#"{"hook_event_name":"Notification","session_id":"A","notification_type":"permission_prompt","message":"Claude needs permission"}"#, at: clock)])
    a = store.sessions["A"]!
    expect(a.mood == .attention && a.attentionText == "Needs your OK: Push the fix", "permission keeps the richer text")
    expect(played == ["Ping"], "one ping for one request, got \(played)")
    expect(store.peek == "A", "opens for a session that needs you")

    store.apply([event(#"{"hook_event_name":"PostToolUse","session_id":"A"}"#, at: clock)])
    expect(store.sessions["A"]!.mood == .working && store.peek == nil, "answering closes the peek")

    clock = clock.addingTimeInterval(65)
    store.apply([event(#"{"hook_event_name":"Stop","session_id":"A"}"#, at: clock)])
    a = store.sessions["A"]!
    expect(a.mood == .done && a.activity == "Finished in 1m 5s" && !a.acknowledged, "finish with duration")
    expect(played == ["Ping", "Glass"] && store.unseenDoneCount == 1 && store.hasNews, "finished waits for you")
    store.markFinishedSeen()
    expect(store.unseenDoneCount == 0 && !store.hasNews && store.overallMood == .idle, "hover marks finished as seen")

    // MARK: quiet paths
    store.apply([event(#"{"hook_event_name":"Notification","session_id":"A","notification_type":"idle_prompt","message":"waiting"}"#, at: clock)])
    expect(store.sessions["A"]!.mood == .done, "idle_prompt ignored")
    store.apply([event(#"{"hook_event_name":"UserPromptSubmit","session_id":"B","prompt":"old"}"#, at: clock.addingTimeInterval(-60)),
                 event(#"{"hook_event_name":"PermissionRequest","session_id":"B","tool_name":"Bash","tool_input":{}}"#, at: clock.addingTimeInterval(-59))])
    expect(store.sessions["B"]!.mood == .attention && played.count == 2 && store.peek != "B", "replayed events stay silent")
    store.apply([event(#"{"hook_event_name":"SessionEnd","session_id":"B"}"#, at: clock)])
    expect(store.sessions["B"] == nil, "session end removes")

    // A session first seen mid-turn (e.g. after Buddy restarts) still gets its project name.
    store.apply([event(#"{"hook_event_name":"PostToolUse","session_id":"D"}"#, at: clock)])
    expect(store.sessions["D"] == nil, "a trimmed PostToolUse does not create a nameless session")
    store.apply([event(#"{"hook_event_name":"Stop","session_id":"D"}"#, at: clock),
                 event(#"{"hook_event_name":"PreToolUse","session_id":"D","cwd":"/p/Notes","tool_name":"Read","tool_input":{}}"#, at: clock)])
    expect(store.sessions["D"]?.project == "Notes", "project filled in from a later event")
    store.dismiss("D")

    // MARK: chat titles from the Claude app's session files
    let titleRoot = scratch.appendingPathComponent("claude-code-sessions/acct/org", isDirectory: true)
    try! FileManager.default.createDirectory(at: titleRoot, withIntermediateDirectories: true)
    let padding = String(repeating: "x", count: 50_000)
    try! Data(#"{"sessionId":"local_aaa-1","cwd":"/p/my-app","title":"Fix \"login\" flow","big":"\#(padding)"}"#.utf8)
        .write(to: titleRoot.appendingPathComponent("local_aaa-1.json"))
    let titles = ChatTitles(root: scratch.appendingPathComponent("claude-code-sessions"))
    expect(titles.title(for: "local_aaa-1") == "Fix \"login\" flow", "title with escaped quotes")
    expect(titles.title(for: "local_missing") == nil && titles.title(for: "../../etc") == nil, "missing or malformed id")

    var titleClock = Date()
    let named = Store(defaults: defaults, sound: { _ in }, now: { titleClock }, titles: titles)
    let appHost = "com.anthropic.claudefordesktop\tlocal_aaa-1\t"
    named.apply([event(#"{"hook_event_name":"UserPromptSubmit","session_id":"N","cwd":"/p/my-app","prompt":"go"}"#, host: appHost, at: titleClock)])
    expect(named.sessions["N"]?.name == "Fix \"login\" flow", "chat title replaces the folder name")

    // MARK: click or swipe clears a row until something new happens
    named.apply([event(#"{"hook_event_name":"PermissionRequest","session_id":"N","tool_name":"Bash","tool_input":{}}"#, host: appHost, at: titleClock)])
    expect(named.attentionCount == 1 && named.peek == "N", "needs you")
    named.dismiss("N")
    expect(named.ordered.isEmpty && named.attentionCount == 0 && !named.hasNews && named.peek == nil, "cleared: gone from list, badge and peek")
    named.apply([event(#"{"hook_event_name":"PostToolUse","session_id":"N"}"#, host: appHost, at: titleClock)])
    expect(named.ordered.isEmpty, "routine activity keeps it cleared")
    titleClock = titleClock.addingTimeInterval(5)
    named.apply([event(#"{"hook_event_name":"Stop","session_id":"N"}"#, host: appHost, at: titleClock)])
    expect(named.ordered.first?.id == "N" && named.unseenDoneCount == 1, "finishing brings it back")
    named.dismiss("N")
    named.apply([event(#"{"hook_event_name":"UserPromptSubmit","session_id":"N","prompt":"next"}"#, host: appHost, at: titleClock)])
    expect(named.ordered.first?.id == "N" && named.workingCount == 1, "a new prompt brings it back")

    // MARK: scrolling list geometry (rows are 46 pt + 2 pt spacing)
    expect(RowLayout.listHeight(rows: 0) == 48 && RowLayout.listHeight(rows: 3) == 144, "list grows with rows")
    expect(RowLayout.listHeight(rows: 20) == RowLayout.listHeight(rows: 6), "list stops growing at six rows, then scrolls")
    expect(RowLayout.index(atDistanceIntoList: 10, scrolled: 0, count: 9) == 0, "first row")
    expect(RowLayout.index(atDistanceIntoList: 50, scrolled: 0, count: 9) == 1, "second row")
    expect(RowLayout.index(atDistanceIntoList: 10, scrolled: 144, count: 9) == 3, "scrolled three rows down")
    expect(RowLayout.index(atDistanceIntoList: 280, scrolled: 144, count: 9) == 8, "ninth row once scrolled")
    expect(RowLayout.index(atDistanceIntoList: 300, scrolled: 144, count: 9) == nil, "past the last row")
    expect(RowLayout.index(atDistanceIntoList: -5, scrolled: 0, count: 9) == nil, "above the list (header)")

    // MARK: usage-limit reset times
    func at(_ text: String, _ zone: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: zone)
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: text)!
    }
    let limitText = "You've hit your session limit · resets 3:30pm (America/Chicago)"
    expect(ResetTime.parse(limitText, after: at("2026-10-18 13:05", "America/Chicago")) == at("2026-10-18 15:30", "America/Chicago"), "same-day reset")
    expect(ResetTime.parse("You've hit your session limit · resets 1am (Europe/London)", after: at("2026-10-18 23:10", "Europe/London"))
           == at("2026-10-19 01:00", "Europe/London"), "reset after midnight")
    expect(ResetTime.parse("You've hit your weekly limit · resets Oct 20, 9am (America/Chicago)", after: at("2026-10-18 10:00", "America/Chicago"))
           == at("2026-10-20 09:00", "America/Chicago"), "weekly reset with a date")
    expect(ResetTime.parse("You've hit your weekly limit · resets Jan 2 at 9am (America/Chicago)", after: at("2026-12-30 10:00", "America/Chicago"))
           == at("2027-01-02 09:00", "America/Chicago"), "date in the new year")
    expect(ResetTime.parse("resets 12pm (America/Chicago)", after: at("2026-10-18 09:00", "America/Chicago")) == at("2026-10-18 12:00", "America/Chicago"), "noon")
    expect(ResetTime.parse("Rate limited, try again", after: Date()) == nil, "no time in the message")
    expect(ResetTime.parse("resets 3pm (Not/AZone)", after: Date()) == nil, "unknown time zone")

    // MARK: a usage limit pauses chats; the backup gets the ones still paused
    var limitClock = at("2026-10-18 13:05", "America/Chicago")
    var handedOver: [String] = []
    let limited = Store(defaults: defaults, sound: { _ in }, now: { limitClock }, titles: titles)
    limited.onContinue = { sessions, _ in handedOver = sessions.map(\.id).sorted() }
    for id in ["L1", "L2"] {
        limited.apply([event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(id)","prompt":"work"}"#, at: limitClock),
                       event(#"{"hook_event_name":"StopFailure","session_id":"\#(id)","error":"rate_limit","last_assistant_message":"\#(limitText)"}"#, at: limitClock)])
    }
    expect(limited.pausedSessions.count == 2 && limited.sessions["L1"]?.activity == "Paused by your usage limit", "limit pauses chats")
    expect(limited.limitResetsAt == at("2026-10-18 15:30", "America/Chicago") && !limited.limitHasReset, "countdown target")
    expect(limited.hasNews && limited.workingCount == 0, "paused chats keep the pill up")
    defaults.set(true, forKey: "autoTypeContinue")
    expect(limited.autoContinueAt == at("2026-10-18 15:36", "America/Chicago"), "backup waits six minutes past the reset")
    limitClock = at("2026-10-18 15:31", "America/Chicago")
    expect(limited.limitHasReset, "reset reached")
    // Claude Code's own auto-continue resumes L1; only L2 is handed to the typer.
    limited.apply([event(#"{"hook_event_name":"PreToolUse","session_id":"L1","tool_name":"Read","tool_input":{}}"#, at: limitClock)])
    expect(limited.sessions["L1"]?.mood == .working && limited.sessions["L1"]?.limitResetsAt == nil, "resumed chat leaves paused")
    limited.continuePaused()
    expect(handedOver == ["L2"], "only still-paused chats are continued, got \(handedOver)")
    limited.clearFinished()
    expect(limited.sessions["L2"] != nil, "Clear Finished keeps paused chats")
    limited.apply([event(#"{"hook_event_name":"StopFailure","session_id":"L3","error":"overloaded"}"#, at: limitClock)])
    expect(limited.sessions["L3"]?.mood == .attention && limited.sessions["L3"]?.attentionText == "Stopped by an API error (overloaded)", "other API errors need you")
    defaults.removeObject(forKey: "autoTypeContinue")

    // MARK: finding chats paused before Buddy was listening
    let appRoot = scratch.appendingPathComponent("scan/claude-code-sessions/acct/org", isDirectory: true)
    let projects = scratch.appendingPathComponent("scan/projects/-p-Purplelink-LLC", isDirectory: true)
    try! FileManager.default.createDirectory(at: appRoot, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    func chat(_ local: String, cli: String, archived: Bool = false, title: String, transcript lines: [String]) {
        let meta = #"{"sessionId":"\#(local)","cliSessionId":"\#(cli)","cwd":"/p/my-app","isArchived":\#(archived),"title":"\#(title)","big":"\#(padding)"}"#
        try! Data(meta.utf8).write(to: appRoot.appendingPathComponent("\(local).json"))
        try! (lines.joined(separator: "\n") + "\n").write(to: projects.appendingPathComponent("\(cli).jsonl"), atomically: true, encoding: .utf8)
    }
    let userPrompt = #"{"type":"user","message":{"role":"user","content":"do it"},"timestamp":"2026-10-18T19:00:00.000Z"}"#
    let limitHit = #"{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","timestamp":"2026-10-18T20:05:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"You've hit your session limit · resets 3:30pm (America/Chicago)"}]}}"#
    let costState = #"{"type":"cost-state"}"#
    let reply = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]},"timestamp":"2026-10-18T23:00:00.000Z"}"#
    chat("local_p1", cli: "cli-paused", title: "Paused chat", transcript: [userPrompt, limitHit, costState])
    chat("local_p2", cli: "cli-archived", archived: true, title: "Archived chat", transcript: [userPrompt, limitHit])
    chat("local_p3", cli: "cli-moved-on", title: "Moved on", transcript: [userPrompt, limitHit, userPrompt, reply])
    chat("local_p4", cli: "cli-cleared", title: "Cleared by you", transcript: [userPrompt, limitHit])

    let scanner = PausedScan(sessionsRoot: scratch.appendingPathComponent("scan/claude-code-sessions"),
                             projectsRoot: scratch.appendingPathComponent("scan/projects"))
    let scanned = scanner.run().sorted { $0.id < $1.id }
    expect(scanned.map(\.id) == ["cli-cleared", "cli-paused"], "finds only paused, unarchived chats, got \(scanned.map(\.id))")
    let p1 = scanned.first { $0.id == "cli-paused" }
    expect(p1?.title == "Paused chat" && p1?.mood == .paused && p1?.host.desktopSessionID == "local_p1", "scanned chat has its title and jump target")
    expect(p1?.limitResetsAt == at("2026-10-18 15:30", "America/Chicago"), "reset read from the transcript, got \(String(describing: p1?.limitResetsAt))")

    var scanClock = at("2026-10-18 14:00", "America/Chicago")
    let merged = Store(defaults: defaults, sound: { _ in }, now: { scanClock }, titles: titles)
    merged.apply([event(#"{"hook_event_name":"UserPromptSubmit","session_id":"cli-cleared","cwd":"/p","prompt":"x"}"#, at: scanClock)])
    merged.dismiss("cli-cleared")
    merged.adoptScan(scanned)
    expect(merged.sessions["cli-paused"]?.mood == .paused && merged.pausedSessions.count == 1, "scan adds paused chats it had not heard of")
    expect(merged.sessions["cli-cleared"]?.mood == .working && merged.sessions["cli-cleared"]?.hidden == true, "live events win over the scan")
    expect(merged.limitResetsAt == at("2026-10-18 15:30", "America/Chicago") && merged.hasNews, "countdown from scanned chats")
    merged.adoptScan(scanned)
    expect(merged.pausedSessions.count == 1, "rescanning does not duplicate")
    merged.dismiss("cli-paused")
    merged.adoptScan(scanned)
    expect(merged.sessions["cli-paused"]?.hidden == true, "rescan keeps a cleared scanned chat cleared")
    merged.adoptScan([])
    expect(merged.sessions["cli-paused"] == nil && merged.sessions["cli-cleared"] != nil, "a scanned pause that ended drops out; live ones stay")
    scanClock = scanClock.addingTimeInterval(1)

    // MARK: connecting to Claude Code from the app
    let guardHook: [String: Any] = ["matcher": "Bash", "hooks": [["type": "command", "command": "python3 guard.py"]]]
    let existing: [String: Any] = ["model": "x", "hooks": ["PreToolUse": [guardHook]]]
    let merged1 = HookSetup.merged(existing)
    let pre = (merged1["hooks"] as? [String: Any])?["PreToolUse"] as? [Any] ?? []
    expect(pre.count == 2 && !HookSetup.isBuddy(pre[0]) && HookSetup.isBuddy(pre[1]), "keeps the user's hook, adds Buddy's after it")
    expect(HookSetup.hasBuddy(merged1) && (merged1["model"] as? String) == "x", "other settings untouched")
    let merged2 = HookSetup.merged(merged1)
    expect(NSDictionary(dictionary: merged1).isEqual(to: merged2), "connecting twice changes nothing")
    let back = HookSetup.unmerged(merged2)
    expect(NSDictionary(dictionary: back).isEqual(to: existing), "disconnect restores the original exactly")
    expect(HookSetup.unmerged(HookSetup.merged([:])).isEmpty, "no settings before, none after")

    let claudeDir = scratch.appendingPathComponent("claude-home/.claude", isDirectory: true)
    let fakeHook = scratch.appendingPathComponent("fake-hook")
    try! Data("#!/bin/sh\n".utf8).write(to: fakeHook)
    try! FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    try! JSONSerialization.data(withJSONObject: existing).write(to: claudeDir.appendingPathComponent("settings.json"))
    let setup = HookSetup(claudeDir: claudeDir, bundledHook: fakeHook)
    expect(!setup.isConnected, "starts disconnected")
    try! setup.connect()
    let backups = (try? FileManager.default.contentsOfDirectory(atPath: claudeDir.path))?.filter { $0.hasPrefix("settings.json.bak-buddy-") } ?? []
    expect(setup.isConnected && FileManager.default.isExecutableFile(atPath: setup.hookURL.path) && backups.count == 1,
           "connect installs the hook, wires settings, keeps one backup")
    try! setup.connect()
    let backupsAfter = (try? FileManager.default.contentsOfDirectory(atPath: claudeDir.path))?.filter { $0.hasPrefix("settings.json.bak-buddy-") } ?? []
    expect(backupsAfter.count == 1, "a second connect writes nothing new")
    try! setup.disconnect()
    expect(!setup.isConnected && !FileManager.default.fileExists(atPath: setup.hookURL.path), "disconnect removes entries and the hook")

    // MARK: Auto continues each chat at its own reset (2026-10-20: chats paused together reset
    // at 8:50 and 9:40 PM, and the old single countdown waited for the later one)
    var autoClock = at("2026-10-20 20:40", "America/New_York")
    var autoHanded: [[String]] = []
    let auto = Store(defaults: defaults, sound: { _ in }, now: { autoClock }, titles: titles)
    auto.onContinue = { sessions, manual in if !manual { autoHanded.append(sessions.map(\.id).sorted()) } }
    defaults.set(true, forKey: "autoTypeContinue")
    let appHost2 = "com.anthropic.claudefordesktop\tlocal_aaa-1\t"
    func pauseEvent(_ id: String, _ reset: String, host: String) -> [HookEvent] {
        [event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(id)","prompt":"work"}"#, host: host, at: autoClock),
         event(#"{"hook_event_name":"StopFailure","session_id":"\#(id)","error":"rate_limit","last_assistant_message":"You've hit your session limit · resets \#(reset) (America/New_York)"}"#, host: host, at: autoClock)]
    }
    auto.apply(pauseEvent("early", "8:50pm", host: appHost2) + pauseEvent("late", "9:40pm", host: appHost2)
               + pauseEvent("term", "8:50pm", host: "com.apple.Terminal\t\tttys004"))
    expect(auto.limitResetsAt == at("2026-10-20 20:50", "America/New_York"), "countdown shows the next reset, not the last")
    expect(auto.autoContinueAt == at("2026-10-20 20:51", "America/New_York"), "a Claude app chat is due one minute after its own reset")
    autoClock = at("2026-10-20 20:51", "America/New_York")
    auto.runAutoContinue()
    expect(autoHanded == [["early"]], "8:51: only the chat whose limit reset is continued, got \(autoHanded)")
    expect(auto.limitHasReset && auto.limitResetsAt == at("2026-10-20 21:40", "America/New_York"), "banner: one ready, counting to the next")
    autoClock = at("2026-10-20 20:56", "America/New_York")
    auto.runAutoContinue()
    expect(autoHanded.last == ["early", "term"], "8:56: the terminal session (six-minute wait) and a retry of the still-paused chat, got \(autoHanded)")
    autoClock = at("2026-10-20 21:41", "America/New_York")
    auto.runAutoContinue()
    expect(autoHanded.last?.contains("late") == true, "9:41: the later chat at its own reset, got \(String(describing: autoHanded.last))")
    for minute in stride(from: 45, through: 59, by: 3) {
        autoClock = at("2026-10-20 21:\(minute)", "America/New_York")
        auto.runAutoContinue()
    }
    let earlyTries = autoHanded.filter { $0.contains("early") }.count
    expect(earlyTries == 3 && auto.sessions["early"]?.continueAttempts == 3, "at most three tries per chat, got \(earlyTries)")

    // MARK: Skipped tries don't count, and unlocking retries them at once (2026-10-22: the Mac
    // locked overnight and the tries ran out without ever reaching the chats)
    var lockClock = at("2026-10-21 21:22", "America/New_York")
    var lockHanded = 0
    let locked = Store(defaults: defaults, sound: { _ in }, now: { lockClock }, titles: titles)
    locked.onContinue = { sessions, manual in if !manual { lockHanded += 1; sessions.forEach { locked.continueSkipped($0.id) } } }
    locked.apply([event(#"{"hook_event_name":"UserPromptSubmit","session_id":"night","prompt":"work"}"#, host: appHost2, at: lockClock),
                  event(#"{"hook_event_name":"StopFailure","session_id":"night","error":"rate_limit","last_assistant_message":"You've hit your session limit · resets 12:20am (America/New_York)"}"#, host: appHost2, at: lockClock)])
    for minute in stride(from: 21, through: 57, by: 3) {
        lockClock = at("2026-10-22 00:\(minute)", "America/New_York")
        locked.runAutoContinue()
    }
    expect(lockHanded == 13 && locked.sessions["night"]?.continueAttempts == 0,
           "skipped tries (locked screen) keep coming every 3 minutes and use up none of the three, got \(lockHanded) tries, \(locked.sessions["night"]?.continueAttempts ?? -1) counted")
    lockClock = at("2026-10-22 01:00", "America/New_York")
    locked.runAutoContinue()
    expect(lockHanded == 14, "a try is due again after the gap")
    lockClock = at("2026-10-22 01:01", "America/New_York")
    locked.screenUnlocked()
    expect(lockHanded == 15, "unlocking retries a skipped chat at once, without waiting for the gap")
    locked.onContinue = { _, manual in if !manual { lockHanded += 1 } }  // this time it reaches the chat
    lockClock = at("2026-10-22 01:05", "America/New_York")
    locked.runAutoContinue()
    expect(locked.sessions["night"]?.continueAttempts == 1, "a try that reaches the chat counts")
    defaults.set(true, forKey: "keepAwakeForAuto")
    expect(locked.keepAwakeOn && locked.autoContinuePending, "keep-awake wants the display on while Auto still has a chat to try")
    defaults.set(false, forKey: "autoTypeContinue")
    expect(!locked.autoContinuePending, "nothing pending once Auto is off")
    defaults.set(true, forKey: "autoTypeContinue")
    defaults.removeObject(forKey: "keepAwakeForAuto")

    // A pause from yesterday is left alone; a rescan of the same pause keeps the count.
    let rescanStore = Store(defaults: defaults, sound: { _ in }, now: { autoClock }, titles: titles)
    var stale = auto.sessions["early"]!
    stale.fromScan = true
    stale.limitResetsAt = at("2026-10-19 08:00", "America/New_York")
    stale.continueAttempts = 0
    stale.lastContinueAttempt = nil
    rescanStore.adoptScan([stale])
    expect(rescanStore.autoContinueAt == nil, "Auto ignores a chat whose limit reset over 12 hours ago")
    var fresh = stale
    fresh.limitResetsAt = at("2026-10-20 21:58", "America/New_York")
    rescanStore.adoptScan([fresh])
    autoClock = at("2026-10-20 21:59", "America/New_York")
    var scanHanded = 0
    rescanStore.onContinue = { _, manual in if !manual { scanHanded += 1 } }
    rescanStore.runAutoContinue()
    rescanStore.adoptScan([fresh])  // the 10-minute rescan finds the same pause
    expect(rescanStore.sessions[fresh.id]?.continueAttempts == 1 && scanHanded == 1, "rescan keeps the attempt count")
    defaults.removeObject(forKey: "autoTypeContinue")

    // MARK: list order: orange, then green, then blue, even after hovering marks green as seen
    let orderClock = Date()
    let order = Store(defaults: defaults, sound: { _ in }, now: { orderClock }, titles: titles)
    order.apply([
        event(#"{"hook_event_name":"UserPromptSubmit","session_id":"green","prompt":"a"}"#, at: orderClock.addingTimeInterval(-300)),
        event(#"{"hook_event_name":"Stop","session_id":"green"}"#, at: orderClock.addingTimeInterval(-200)),
        event(#"{"hook_event_name":"UserPromptSubmit","session_id":"blue","prompt":"b"}"#, at: orderClock.addingTimeInterval(-10)),
        event(#"{"hook_event_name":"UserPromptSubmit","session_id":"orange","prompt":"c"}"#, at: orderClock.addingTimeInterval(-400)),
        event(#"{"hook_event_name":"PermissionRequest","session_id":"orange","tool_name":"Bash","tool_input":{}}"#, at: orderClock.addingTimeInterval(-390)),
    ])
    expect(order.ordered.map(\.id) == ["orange", "green", "blue"], "orange, green, blue, got \(order.ordered.map(\.id))")
    order.markFinishedSeen()
    expect(order.ordered.map(\.id) == ["orange", "green", "blue"], "green stays above blue after hovering, got \(order.ordered.map(\.id))")

    // MARK: settings: two sounds, the old single switch carried over, retries switchable
    let soundDefaults = UserDefaults(suiteName: "buddy-tests-sound-\(UUID().uuidString)")!
    soundDefaults.set(true, forKey: "muted")  // a pre-0.4 "Sounds off"
    var heard: [String] = []
    let soundClock = Date()
    let sounds = Store(defaults: soundDefaults, sound: { heard.append($0) }, now: { soundClock }, titles: titles)
    expect(!sounds.soundForAttention && !sounds.soundForDone && soundDefaults.object(forKey: "muted") == nil,
           "the old Sounds off becomes both sounds off, once")
    sounds.soundForAttention = true
    sounds.apply([event(#"{"hook_event_name":"UserPromptSubmit","session_id":"S1","prompt":"x"}"#, at: soundClock),
                  event(#"{"hook_event_name":"PermissionRequest","session_id":"S1","tool_name":"Bash","tool_input":{}}"#, at: soundClock),
                  event(#"{"hook_event_name":"Stop","session_id":"S1"}"#, at: soundClock)])
    expect(heard == ["Ping"], "only the needs-you sound plays, got \(heard)")
    sounds.retryConnectionsOn = false
    var retriedWhileOff = 0
    sounds.onRetry = { _ in retriedWhileOff += 1 }
    sounds.apply([event(#"{"hook_event_name":"StopFailure","session_id":"S2","error":"server_error","last_assistant_message":"API Error: Connection lost mid-response."}"#, at: soundClock)])
    sounds.retryDisconnected(fresh: true)
    expect(retriedWhileOff == 0, "no automatic retries when the setting is off")

    // MARK: usage estimate and exact usage parsing
    expect(UsageEstimate.weight(model: "claude-sonnet-4-5", input: 100, output: 10, cacheWrite: 0, cacheRead: 1000) == 250,
           "weights: input 1, output 5, cache read 0.1 (Sonnet)")
    expect(abs(UsageEstimate.weight(model: "claude-opus-5-5", input: 100, output: 0, cacheWrite: 0, cacheRead: 0) - 167) < 0.01, "Opus counts 1.67x")
    let base = at("2026-10-21 08:00", "America/New_York")
    func estReply(_ minutes: Double, _ w: Double) -> UsageReply { UsageReply(date: base.addingTimeInterval(minutes * 60), weight: w) }
    // One past limit: window 08:00-13:00 hit at 12:00 after 1000 units.
    let pastLimit = UsageLimit(hitAt: base.addingTimeInterval(4 * 3600), resetsAt: base.addingTimeInterval(5 * 3600))
    let replies = [estReply(10, 400), estReply(120, 600), estReply(310, 100), estReply(330, 150)]  // 13:10 and 13:30 start a new window
    expect(UsageEstimate.capacity(replies: replies, limits: [pastLimit]) == 1000, "capacity is what the limit took")
    let afternoon = base.addingTimeInterval(6 * 3600)  // 14:00
    let win = UsageEstimate.currentWindow(replies: replies, limits: [pastLimit], now: afternoon)
    expect(win?.start == base.addingTimeInterval(310 * 60) && win?.end == base.addingTimeInterval(610 * 60), "window starts at the first reply after the reset")
    let est = UsageEstimate.reading(replies: replies, limits: [pastLimit], now: afternoon)
    expect(est.session?.percent == 25 && !est.exact, "250 of 1000 = 25%, got \(String(describing: est.session?.percent))")
    expect(UsageEstimate.reading(replies: replies, limits: [], now: afternoon).session == nil, "no estimate before any limit")
    let pending = UsageEstimate.currentWindow(replies: replies, limits: [pastLimit], now: base.addingTimeInterval(4.5 * 3600))
    expect(pending?.end == pastLimit.resetsAt, "while limited, the window is the one the limit names")

    // The scanner counts a streamed reply once and uses session limits only.
    let usageProjects = scratch.appendingPathComponent("usage/projects/-p", isDirectory: true)
    try! FileManager.default.createDirectory(at: usageProjects, withIntermediateDirectories: true)
    let iso2 = ISO8601DateFormatter()
    let t = Date().addingTimeInterval(-3600)
    func usageLine(_ id: String, _ out: Int, _ date: Date) -> String {
        #"{"type":"assistant","timestamp":"\#(iso2.string(from: date))","message":{"id":"\#(id)","model":"claude-sonnet-4-5","usage":{"input_tokens":0,"output_tokens":\#(out),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
    }
    let weeklyLimit = #"{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","timestamp":"\#(iso2.string(from: t))","message":{"content":[{"type":"text","text":"You've hit your weekly limit · resets Oct 30, 9am (America/Chicago)"}]}}"#
    try! ([usageLine("m1", 10, t), usageLine("m1", 40, t), usageLine("m2", 20, t), weeklyLimit].joined(separator: "\n") + "\n")
        .write(to: usageProjects.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
    _ = UsageScanner(projectsRoot: scratch.appendingPathComponent("usage/projects")).scan()  // no session limit: no estimate, no crash
    expect(true, "scanner runs on synthetic transcripts")

    let exactJSON = #"{"five_hour":{"utilization":42.5,"resets_at":"2026-10-21T18:20:00+00:00"},"seven_day":{"utilization":17,"resets_at":"2026-10-25T13:00:00+00:00"},"seven_day_opus":null}"#
    let exactReading = ExactUsage.parse(Data(exactJSON.utf8))
    expect(exactReading?.exact == true && exactReading?.session?.percent == 42.5 && exactReading?.week?.percent == 17, "exact usage parses")
    expect(ExactUsage.parse(Data(#"{"error":"x"}"#.utf8)) == nil, "unexpected answers are rejected")
    expect(ExactUsage.Failure.noSignIn.signInHelps && ExactUsage.Failure.expired.signInHelps
           && ExactUsage.Failure.refused(401).signInHelps, "sign-in failures offer Sign In")
    expect(!ExactUsage.Failure.keychainDenied.signInHelps, "a refused keychain prompt does not offer Sign In")
    expect(!ExactUsage.Failure.offline.signInHelps && !ExactUsage.Failure.unreadable.signInHelps,
           "network and format failures do not offer Sign In")
    expect(ClaudeAccount.parse(Data(#"{"loggedIn":true,"email":"a@b.c","orgName":"Org"}"#.utf8)) == ClaudeAccount(email: "a@b.c", orgName: "Org"),
           "auth status gives the signed-in account")
    expect(ClaudeAccount.parse(Data(#"{"loggedIn":false}"#.utf8)) == nil, "signed out reads as no account")
    expect(ClaudeAccount.parse(Data(#"{"loggedIn":true,"email":"a@b.c","orgName":""}"#.utf8))?.orgName == nil, "empty org is dropped")

    // MARK: chats stopped by a dropped connection
    for message in ["API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)",
                    "API Error: Connection lost mid-response. The response above may be incomplete.",
                    "API Error: Your computer went to sleep mid-response. The response above may be incomplete."] {
        expect(Store.isConnectionError("server_error", message), "network error: \(message.prefix(40))")
    }
    expect(!Store.isConnectionError("server_error", "API Error: 500 Internal server error"), "a plain 500 is not a dropped connection")
    expect(!Store.isConnectionError("rate_limit", "Can't reach the API server"), "a limit is never a connection drop")
    expect(!Store.isConnectionError("authentication_failed", "Not logged in"), "auth errors are not connection drops")

    let netClock = Date()
    var retried: [[String]] = []
    var stoppedWhenCalled = -1
    let net = Store(defaults: defaults, sound: { _ in }, now: { netClock }, titles: titles)
    net.onRetry = { retried.append($0.map(\.id)) }
    net.onConnectionLost = { stoppedWhenCalled = net.disconnectedSessions.count }
    net.apply([event(#"{"hook_event_name":"UserPromptSubmit","session_id":"X","cwd":"/p/acme","prompt":"go"}"#, at: netClock),
               event(#"{"hook_event_name":"StopFailure","session_id":"X","error":"server_error","last_assistant_message":"API Error: Connection lost mid-response."}"#, at: netClock)])
    expect(net.disconnectedSessions.map(\.id) == ["X"] && net.pausedSessions.isEmpty && net.hasNews,
           "connection drop is its own kind of pause (no limit banner)")
    expect(net.sessions["X"]?.activity == Store.connectionLostText, "row says it will retry")
    expect(stoppedWhenCalled == 1, "the app is told after the chat is saved as stopped, got \(stoppedWhenCalled)")
    for _ in 0..<4 { net.retryDisconnected(fresh: false) }
    expect(retried.count == 3, "at most three automatic tries, got \(retried.count)")
    net.retryDisconnected(fresh: true)
    expect(retried.count == 4, "network back: tries start over")
    net.apply([event(#"{"hook_event_name":"PreToolUse","session_id":"X","tool_name":"Read","tool_input":{}}"#, at: netClock)])
    expect(net.disconnectedSessions.isEmpty && net.workingCount == 1, "a retried chat that resumes is working again")
    net.apply([event(#"{"hook_event_name":"StopFailure","session_id":"Y","error":"server_error","last_assistant_message":"API Error: 500 Internal server error"}"#, at: netClock)])
    expect(net.sessions["Y"]?.mood == .attention, "other server errors still need you")

    // The scan adopts a recent drop but never an old one.
    let iso = ISO8601DateFormatter()
    let dropText = "API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)"
    func dropEntry(_ date: Date) -> String {
        #"{"type":"assistant","isApiErrorMessage":true,"error":"server_error","timestamp":"\#(iso.string(from: date))","message":{"role":"assistant","content":[{"type":"text","text":"\#(dropText)"}]}}"#
    }
    chat("local_n1", cli: "cli-net-recent", title: "Dropped just now", transcript: [userPrompt, dropEntry(Date().addingTimeInterval(-120))])
    chat("local_n2", cli: "cli-net-old", title: "Dropped long ago", transcript: [userPrompt, dropEntry(Date().addingTimeInterval(-7 * 3600))])
    let netScan = scanner.run()
    let recent = netScan.first { $0.id == "cli-net-recent" }
    expect(recent?.pauseReason == .connection && recent?.limitResetsAt == nil, "scan finds a recent connection drop")
    expect(!netScan.contains { $0.id == "cli-net-old" }, "scan leaves a 7-hour-old drop alone")

    // MARK: interrupt detection from the transcript tail
    func transcript(_ name: String, _ lines: [String]) -> String {
        let url = scratch.appendingPathComponent(name)
        try! (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
    let assistant = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}"#
    let marker = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
    let mention = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"23 [Request interrupted by user]"}]}}"#
    let bookkeeping = #"{"type":"queue-operation"}"#
    expect(Transcript.wasInterrupted(at: transcript("i1", [assistant, marker, bookkeeping, bookkeeping])), "marker then bookkeeping")
    expect(!Transcript.wasInterrupted(at: transcript("i2", [assistant, mention])), "a mention in tool output is not an interrupt")
    expect(!Transcript.wasInterrupted(at: transcript("i3", [marker, assistant])), "Claude carried on after the marker")
    expect(!Transcript.wasInterrupted(at: scratch.appendingPathComponent("missing").path), "missing transcript")
    let big = #"{"type":"attachment","x":""# + String(repeating: "y", count: 80_000) + #""}"#
    expect(Transcript.wasInterrupted(at: transcript("i4", [assistant, marker, big])) == false,
           "marker beyond the 64 KB tail is not seen (safe direction)")
    expect(Transcript.wasInterrupted(at: transcript("i5", [big, assistant, marker])), "partial first line is skipped")

    let path = transcript("i6", [assistant, marker])
    store.apply([event(#"{"hook_event_name":"UserPromptSubmit","session_id":"C","prompt":"go","transcript_path":"\#(path)"}"#, at: clock)])
    clock = clock.addingTimeInterval(30)
    store.checkQuietSessions()
    let c = store.sessions["C"]!
    expect(c.mood == .idle && c.activity == "Interrupted" && !store.hasNews, "Esc no longer leaves a session stuck")

    // MARK: where a click goes
    let desktop = Host(bundleID: Jump.claudeApp, desktopSessionID: "local_fc2ceb26-6a42-4333", tty: "")
    expect(Jump.target(host: desktop, cwd: "/p") == .desktopChat(sessionID: "local_fc2ceb26-6a42-4333"), "Claude app chat")
    let forged = Host(bundleID: Jump.claudeApp, desktopSessionID: "local_x&foo=bar", tty: "")
    expect(Jump.target(host: forged, cwd: "/p") == .app(bundleID: Jump.claudeApp), "malformed id falls back to the app")
    expect(Jump.target(host: Host(bundleID: Jump.terminal, tty: "ttys004"), cwd: "/p") == .terminalTab(bundleID: Jump.terminal, tty: "ttys004"), "Terminal tab")
    expect(Jump.target(host: Host(bundleID: Jump.terminal, tty: "ttys004\" & quit"), cwd: "/p") == .app(bundleID: Jump.terminal), "bad tty never reaches AppleScript")
    expect(Jump.target(host: Host(bundleID: "com.microsoft.VSCode"), cwd: "/p/x") == .folder(bundleID: "com.microsoft.VSCode", path: "/p/x"), "editor folder")
    expect(Jump.target(host: Host(), cwd: "/p") == .none, "unknown host")

    // MARK: inbox
    let box = scratch.appendingPathComponent("inbox", isDirectory: true)
    try! FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
    try! Data("x\t\t\n{\"session_id\":\"1\"}".utf8).write(to: box.appendingPathComponent("tmp.a.json"))
    Thread.sleep(forTimeInterval: 0.01)
    try! Data("x\t\t\n{\"session_id\":\"2\"}".utf8).write(to: box.appendingPathComponent("tmp.b.json"))
    try! Data("half-written".utf8).write(to: box.appendingPathComponent("tmp.c"))
    var got: [String] = []
    Inbox(url: box) { got = $0.map(\.sessionID) }.drain()
    let left = (try? FileManager.default.contentsOfDirectory(atPath: box.path)) ?? []
    expect(got == ["1", "2"] && left == ["tmp.c"], "inbox drains complete files in order, got \(got), left \(left)")
}

// MARK: the hook binary itself
if let hook = ProcessInfo.processInfo.environment["BUDDY_HOOK"] {
    func run(_ event: String, _ input: String, env extra: [String: String] = [:]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: hook)
        p.arguments = [event]
        p.environment = ["HOME": home, "__CFBundleIdentifier": "com.apple.Terminal",
                         "CLAUDE_CODE_HOST_SESSION_ID": "local_1\tx"].merging(extra) { $1 }
        let pipe = Pipe()
        p.standardInput = pipe
        try! p.run()
        pipe.fileHandleForWriting.write(Data(input.utf8))
        try! pipe.fileHandleForWriting.close()
        p.waitUntilExit()
        expect(p.terminationStatus == 0, "hook exits 0")
    }
    let inbox = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Buddy/inbox")
    run("Stop", #"{"session_id":"S"}"#)
    expect(!FileManager.default.fileExists(atPath: inbox.path), "no inbox: hook writes nothing")

    try! FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let huge = String(repeating: "z", count: 500_000)
    run("PostToolUse", #"{"session_id":"S-1","hook_event_name":"PostToolUse","tool_response":"\#(huge)"}"#)
    let files = try! FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
    let data = try! Data(contentsOf: files[0])
    let parsed = HookEvent(data: data, date: Date())
    expect(files.count == 1 && files[0].pathExtension == "json", "hook leaves one complete .json")
    expect(data.count < 200 && parsed?.sessionID == "S-1" && parsed?.name == "PostToolUse", "PostToolUse trimmed to \(data.count) bytes")
    expect(parsed?.host == Host(bundleID: "com.apple.Terminal", desktopSessionID: "local_1x", tty: ""), "header sanitized: \(String(describing: parsed?.host))")
} else {
    print("skipped hook binary tests (BUDDY_HOOK not set)")
}

// MARK: pace and the weekly window (docs/designs/weekly-usage-pace.md)
do {
    let h: TimeInterval = 3600, d = 24 * h
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func pace(_ p: Double, elapsed: TimeInterval, length: TimeInterval) -> UsagePace? {
        UsagePace.pace(percent: p, resetsAt: now.addingTimeInterval(length - elapsed), length: length, now: now)
    }
    let even = pace(50, elapsed: 2.5 * h, length: UsageReading.sessionLength)
    expect(even?.projected == 100 && even?.runsOutAt == nil, "session 50% halfway: 100%, no run-out")
    let hot = pace(60, elapsed: 2.5 * h, length: UsageReading.sessionLength)
    let start = now.addingTimeInterval(-2.5 * h)
    expect(hot?.projected == 120 && hot?.runsOutAt == start.addingTimeInterval(4 * h + 10 * 60),
           "session 60% at 2.5 h: 120%, runs out 4 h 10 min in, got \(String(describing: hot))")
    let week = pace(60, elapsed: 3.5 * d, length: UsageReading.weekLength)
    let weekStart = now.addingTimeInterval(-3.5 * d)
    expect(week?.projected == 120 && week?.runsOutAt == weekStart.addingTimeInterval(5 * d + 20 * h),
           "week 60% at 3.5 d: 120%, runs out at 5 d 20 h, got \(String(describing: week))")
    let light = pace(20, elapsed: 3.5 * d, length: UsageReading.weekLength)
    expect(light?.projected == 40 && light?.runsOutAt == nil, "a light week: 40%, no run-out")
    expect(pace(30, elapsed: 59 * 60, length: UsageReading.sessionLength) == nil, "no session pace before an hour")
    expect(pace(30, elapsed: 23 * h + 59 * 60, length: UsageReading.weekLength) == nil, "no week pace before 24 hours")
    expect(pace(2, elapsed: 3 * h, length: UsageReading.sessionLength) == nil, "no pace under 3%")
    expect(pace(100, elapsed: 3 * h, length: UsageReading.sessionLength) == nil, "no pace at the limit")
    expect(UsagePace.pace(percent: 40, resetsAt: now.addingTimeInterval(-60), length: UsageReading.sessionLength, now: now) == nil,
           "no pace once the reset has passed")
    expect(UsagePace.pace(percent: 40, resetsAt: nil, length: UsageReading.sessionLength, now: now) == nil, "no pace without a reset")
    expect(UsagePace.pace(percent: 40, resetsAt: now.addingTimeInterval(6 * h), length: UsageReading.sessionLength, now: now) == nil,
           "no pace when the reset does not fit the window (moved or stale)")
    let out = hot!.runsOutAt!.timeIntervalSinceReferenceDate
    expect(out.truncatingRemainder(dividingBy: 300) == 0, "the run-out time is rounded to 5 minutes")
    expect(hot!.sentence(resetsAt: now.addingTimeInterval(2.5 * h), weekly: false).hasPrefix("At this rate, 120% of the limit by the reset"),
           "the hover sentence says 'at this rate'")
    expect(light!.sentence(resetsAt: now, weekly: true).hasSuffix("about 60% left then."), "a light week says what is left")

    let s = UsageReading.Window(percent: 30, resetsAt: now.addingTimeInterval(h))
    let w = UsageReading.Window(percent: 45, resetsAt: now.addingTimeInterval(2 * d))
    let exact = UsageReading(session: s, week: w, exact: true)
    expect(exact.shown(.week, limitPaused: false)?.isWeek == true, "week chosen and exact: the week")
    expect(exact.shown(.session, limitPaused: false)?.isWeek == false, "session chosen: the session")
    expect(exact.shown(.week, limitPaused: true)?.isWeek == false, "a limit pause shows the session, matching its countdown")
    expect(UsageReading(session: s, week: nil, exact: true).shown(.week, limitPaused: false)?.isWeek == false, "no week reading: the session")
    expect(UsageReading(session: s, week: w, exact: false).shown(.week, limitPaused: false)?.isWeek == false, "an estimate never shows a week")
    expect(UsageReading(session: s, week: .init(percent: 45, resetsAt: nil), exact: true).shown(.week, limitPaused: false)?.isWeek == false,
           "a week with no reset time: the session")
    MainActor.assumeIsolated {
        let st = Store(defaults: UserDefaults(suiteName: "buddy-tests-window-\(UUID().uuidString)")!, sound: { _ in }, now: { now })
        expect(st.notchWindow == .session, "the pill shows the session by default")
        st.notchWindow = .week
        expect(st.notchWindow == .week, "the choice is kept")
    }
}

// MARK: usage habits (Sources/Habits.swift; design v3.1). All in UTC so the numbers are exact.
do {
    let utc = TimeZone(identifier: "UTC")!
    let hr: TimeInterval = 3600, dy = 24 * hr
    let monday = ISO8601DateFormatter().date(from: "2026-11-02T00:00:00Z")!     // a Monday, 00:00 UTC
    func hourOf(_ d: Date) -> Int { Int(floor(d.timeIntervalSince1970 / hr)) }
    // Four past weeks of a 9-to-5 weekday habit: 100 weighted tokens an hour, nothing at night or on weekends.
    var data = HabitData()
    var past: [Int: Double] = [:]
    let first = monday.addingTimeInterval(-28 * dy)
    for h in hourOf(first)..<hourOf(monday) {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: utc, from: Date(timeIntervalSince1970: Double(h) * hr))
        let weekday = parts.weekday!, hour = parts.hour!
        if (2...6).contains(weekday), (9..<17).contains(hour) { past[h] = 100 }
    }
    data.set(past, fromHour: hourOf(first), throughHour: hourOf(monday) - 1, offset: { _ in 0 })
    let profile = HabitProfile(data, now: monday)!
    expect(HabitProfile.index(hour: hourOf(monday.addingTimeInterval(10 * hr)), offset: 0) == 24 + 10, "Monday 10:00 is hour 34 of the week")
    expect(HabitProfile.index(hour: hourOf(monday.addingTimeInterval(15 * hr)), offset: -5 * 3600) == 24 + 10,
           "an hour is placed by its own recorded offset (15:00 UTC at UTC-5 is 10:00 local)")
    expect(profile.perHour[24 + 10] > 99 && profile.perHour[24 + 3] < 1, "the profile learns busy days and empty nights")
    let floorValue = 0.02 * (28.0 / 7 * 4000) / Double(28 * 24)
    expect(abs(profile.perHour[24 + 3] - floorValue) < 1e-9, "an unused hour keeps a small floor")
    var young = HabitData()
    young.set([:], fromHour: hourOf(monday) - 20 * 24, throughHour: hourOf(monday) - 1, offset: { _ in 0 })
    expect(HabitProfile(young, now: monday) == nil, "not ready before 21 days")
    let reset = monday.addingTimeInterval(7 * dy)

    // A heavy Monday (double the usual) does not project the heavy day onto the rest of the week.
    var week = data
    var mon: [Int: Double] = [:]
    for h in 9..<17 { mon[hourOf(monday) + h] = 200 }
    week.set(mon, fromHour: hourOf(monday), throughHour: hourOf(monday) + 23, offset: { _ in 0 })
    let tuesday = monday.addingTimeInterval(dy)
    let heavy = UsagePace.weekPace(percent: 40, resetsAt: reset, now: tuesday,
                                   habits: HabitInputs(profile: profile, data: week, recent2h: 0), timeZone: utc)
    let byTime = UsagePace.pace(percent: 40, resetsAt: reset, length: UsageReading.weekLength, now: tuesday)
    expect(heavy?.basis == .habits && heavy!.projected > 115 && heavy!.projected < 130 && byTime!.projected > 250,
           "a heavy Monday: about 122% by habits, not 280% by time; got \(heavy?.projected ?? -1) vs \(byTime?.projected ?? -1)")

    // Working at 3 am, when the habit says nothing happens: the recent burn holds the projection up and sets the run-out.
    var night = week
    var tue: [Int: Double] = [:]
    for h in 9..<17 { tue[hourOf(tuesday) + h] = 100 }
    tue[hourOf(tuesday) + 25] = 200; tue[hourOf(tuesday) + 26] = 200          // Wed 01:00-03:00
    night.set(tue, fromHour: hourOf(tuesday), throughHour: hourOf(tuesday) + 26, offset: { _ in 0 })
    let wed3 = tuesday.addingTimeInterval(27 * hr)                               // Wednesday 03:00
    let burn = UsagePace.weekPace(percent: 50, resetsAt: reset, now: wed3,
                                  habits: HabitInputs(profile: profile, data: night, recent2h: 400), timeZone: utc)
    let calm = UsagePace.weekPace(percent: 50, resetsAt: reset, now: wed3,
                                  habits: HabitInputs(profile: profile, data: night, recent2h: 0), timeZone: utc)
    expect(burn != nil && calm != nil && burn!.projected > calm!.projected, "the recent burn raises the projection at 3 am")
    // This week on this Mac: 1600 + 800 + 400 = 2800 tokens for 50%, so k = 50/2800. The other 50% at the recent burn
    // (400 tokens per 2 hours) takes 14 hours; the habit alone would not get there before the reset.
    expect(burn?.runsOutAt == ISO8601DateFormatter().date(from: "2026-11-04T17:00:00Z"),
           "at that burn it runs out Wednesday 17:00, got \(String(describing: burn?.runsOutAt))")
    expect(burn!.sentence(resetsAt: reset, weekly: true).hasPrefix("At your usual pace"), "habit mode says so")

    // Use mostly from another device (almost nothing on this Mac this week): no habit pace, the caller uses time.
    var elsewhere = data
    elsewhere.set([hourOf(monday) + 10: 1], fromHour: hourOf(monday), throughHour: hourOf(tuesday), offset: { _ in 0 })
    expect(UsagePace.weekPace(percent: 40, resetsAt: reset, now: tuesday,
                              habits: HabitInputs(profile: profile, data: elsewhere, recent2h: 0), timeZone: utc) == nil,
           "too little local use falls back to time")
    expect(UsagePace.weekPace(percent: 40, resetsAt: reset, now: monday.addingTimeInterval(20 * hr),
                              habits: HabitInputs(profile: profile, data: week, recent2h: 0), timeZone: utc) == nil,
           "no week pace in the first 24 hours")

    // The store: set, prune, the edge hour, round trip, a corrupt file, 0600.
    var store = HabitData()
    store.set([10: 5], fromHour: 10, throughHour: 12, offset: { _ in -18000 })
    expect(store.hours["10"] == [5, -18000] && store.hours["11"] == [0, -18000] && store.hours.count == 3,
           "set writes every hour in range, 0 when empty")
    store.set([30: 1], fromHour: 30, throughHour: 30, offset: { _ in 0 })
    store.prune(now: Date(timeIntervalSince1970: (30 + 28 * 24) * hr - 1))
    expect(store.hours.keys.sorted() == ["30"], "hours older than 28 days are pruned")
    let habitsURL = scratch.appendingPathComponent("habits/habits.json")
    let keeper = HabitKeeper(url: habitsURL)
    keeper.load()
    keeper.save()
    let mode = (try? FileManager.default.attributesOfItem(atPath: habitsURL.path)[.posixPermissions] as? NSNumber)?.intValue
    expect(mode == 0o600, "the habits file is private to you, got \(String(describing: mode))")
    try! Data("not json".utf8).write(to: habitsURL)
    let fresh = HabitKeeper(url: habitsURL)
    fresh.load()
    expect(fresh.data == HabitData(), "a corrupt habits file starts empty")
    fresh.forget()
    expect(!FileManager.default.fileExists(atPath: habitsURL.path), "Forget Usage Habits deletes the file")

    // The scanner's whole hours leave out the partial edge hour after the 3-day cutoff.
    let projects = scratch.appendingPathComponent("habits/projects/p")
    try! FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let isoF = ISO8601DateFormatter()
    isoF.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let scanNow = Date()
    let cutoff = scanNow.addingTimeInterval(-3 * dy)
    func line(_ id: String, _ out: Int, _ d: Date) -> String {
        #"{"type":"assistant","timestamp":"\#(isoF.string(from: d))","message":{"id":"\#(id)","model":"claude-sonnet-4-5","usage":{"input_tokens":0,"output_tokens":\#(out),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
    }
    let edge = Date(timeIntervalSince1970: ceil(cutoff.timeIntervalSince1970 / hr) * hr - 1)   // in the partial edge hour
    let inside = Date(timeIntervalSince1970: ceil(cutoff.timeIntervalSince1970 / hr) * hr + 60)
    try! ([line("a", 10, edge), line("b", 10, inside), line("b", 30, inside)].joined(separator: "\n") + "\n")
        .write(to: projects.appendingPathComponent("t.jsonl"), atomically: true, encoding: .utf8)
    let hscan = UsageScanner(projectsRoot: scratch.appendingPathComponent("habits/projects"))
    _ = hscan.scan(now: scanNow)
    let totals = hscan.hourTotals(now: scanNow)
    let insideHour = Int(floor(inside.timeIntervalSince1970 / hr))
    expect(totals.fromHour == insideHour && totals.totals.count == 1 && (totals.totals[insideHour] ?? 0) > 0,
           "whole hours only: the partial edge hour is left out, a streamed reply counts once")
    let caught = hscan.catchUp(fromHour: insideHour - 5, toHour: insideHour, budget: 5)
    expect(caught != nil && caught![insideHour] == totals.totals[insideHour], "the catch-up reads the same reply, once")
}

// MARK: v4.1: learned share, grading, range, budget, Opus, strip (docs/designs/weekly-usage-pace.md)
do {
    let hr: TimeInterval = 3600, dy = 24 * hr
    // An older habits file (no v4 fields) still loads with its hours.
    let old = #"{"version":1,"scannedThrough":1800000000,"hours":{"500000":[12,0]}}"#
    let decoded = try? JSONDecoder().decode(HabitData.self, from: Data(old.utf8))
    expect(decoded?.hours["500000"] == [12, 0] && decoded?.weeks == [] && decoded?.lastWeek == nil,
           "a habits file from before v4 keeps its hours")

    // A week of local use, then readings through it and into the next week.
    let reset1 = Date(timeIntervalSince1970: 1_800_000_000 / 3600 * 3600)
    let start1 = reset1.addingTimeInterval(-7 * dy)
    var d = HabitData()
    var tot: [Int: Double] = [:]
    for h in Int(start1.timeIntervalSince1970 / hr)..<Int(reset1.timeIntervalSince1970 / hr) { tot[h] = 10 }   // 1680 tokens
    d.set(tot, fromHour: Int(start1.timeIntervalSince1970 / hr), throughHour: Int(reset1.timeIntervalSince1970 / hr) - 1, offset: { _ in 0 })
    d.scannedThrough = reset1.timeIntervalSince1970 + hr
    d.observe(percent: 20, resetsAt: reset1, now: start1.addingTimeInterval(2.5 * dy), projected: 70)
    d.observe(percent: 50, resetsAt: reset1, now: start1.addingTimeInterval(4.2 * dy), projected: 95)
    d.observe(percent: 55, resetsAt: reset1, now: start1.addingTimeInterval(4.9 * dy), projected: 99)      // day 4 already kept
    d.observe(percent: 80, resetsAt: reset1, now: start1.addingTimeInterval(6.5 * dy), projected: 85)
    d.observe(percent: 84, resetsAt: reset1.addingTimeInterval(1200), now: reset1.addingTimeInterval(-2 * hr), projected: 84) // jitter: same week
    expect(d.projections == ["2": 70, "4": 95, "6": 85] && d.weeks.isEmpty, "first projection at days 2, 4 and 6; jitter is the same week")
    let reset2 = reset1.addingTimeInterval(7 * dy)
    d.observe(percent: 1, resetsAt: reset2, now: reset1.addingTimeInterval(hr), projected: nil)
    expect(d.weeks.count == 1 && d.weeks[0][1] == 84 && d.weeks[0][2] == 1680, "the week ends when a later reset arrives")
    expect(Array(d.weeks[0][3...]) == [14, 11, 1], "graded by lead time: |70-84|, |95-84|, |85-84|")
    d.observe(percent: 2, resetsAt: reset2, now: reset1.addingTimeInterval(2 * hr), projected: nil)
    expect(d.weeks.count == 1 && d.projections.isEmpty, "the same reset again changes nothing")
    expect(abs(d.learnedK! - 84.0 / 1680) < 1e-12, "the learned share: percent per local token")
    expect(d.band(elapsedDays: 4.5) == (20 * 2 + 11) / 3, "one graded week moves the range a third of the way: \(d.band(elapsedDays: 4.5))")
    expect(HabitData().band(elapsedDays: 3) == 20, "no graded week: ±20")
    expect(d.midWeekAccuracy?.points == 11 && d.midWeekAccuracy?.weeks == 1, "Settings reads the day-4 error")

    var stale = HabitData()
    stale.observe(percent: 60, resetsAt: reset1, now: reset1.addingTimeInterval(-10 * hr), projected: nil)   // last read 10 h early
    stale.observe(percent: 1, resetsAt: reset2, now: reset1.addingTimeInterval(hr), projected: nil)
    expect(stale.weeks.isEmpty, "a week whose last reading was too early, or with no local hours, is not recorded")
    var full = d
    full.weeks.append([reset2.timeIntervalSince1970, 100, 500, -1, -1, -1])
    expect(abs(full.learnedK! - 84.0 / 1680) < 1e-12, "a week that hit the limit is left out of the learned share")

    // Daily budget.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    expect(UsagePace.dailyBudget(percent: 40, resetsAt: now.addingTimeInterval(3 * dy), now: now)?.hasPrefix("About 20% a day at an even pace") == true,
           "60% left over 3 days: about 20% a day")
    expect(UsagePace.dailyBudget(percent: 100, resetsAt: now.addingTimeInterval(dy), now: now) == nil, "no budget at the limit")

    // Opus window.
    let opus = ExactUsage.parse(Data(#"{"five_hour":{"utilization":10,"resets_at":"2026-10-21T18:20:00+00:00"},"seven_day":{"utilization":17,"resets_at":"2026-10-25T13:00:00+00:00"},"seven_day_opus":{"utilization":33,"resets_at":"2026-10-25T13:00:00+00:00"}}"#.utf8))
    expect(opus?.opusWeek?.percent == 33, "the Opus week is read")
    expect(ExactUsage.parse(Data(#"{"seven_day":{"utilization":17,"resets_at":"2026-10-25T13:00:00+00:00"},"seven_day_opus":null}"#.utf8))?.opusWeek == nil,
           "a null Opus week is hidden")

    // The strip's slots start at the window's start, 24 hours each.
    let slots = d.slots(windowStart: start1)
    expect(slots.count == 7 && slots.allSatisfy { $0 == 240 }, "seven 24-hour slots of 240 tokens, got \(slots)")
}

// MARK: account tag and usual limit times (Accounts.swift)
do {
    expect(AccountTag.appUuid(Data(#"{"lastKnownAccountUuid":"aaa","oauth:x":"y"}"#.utf8)) == "aaa", "the app's account uuid is read")
    expect(AccountTag.appUuid(Data("{}".utf8)) == nil, "no app account without the key")
    let code = AccountTag.codeAccount(Data(#"{"oauthAccount":{"accountUuid":"bbb","emailAddress":"me@example.com"}}"#.utf8))
    expect(code?.uuid == "bbb" && code?.email == "me@example.com", "Claude Code's account is read")

    let root = scratch.appendingPathComponent("home", isDirectory: true)
    let fm = FileManager.default
    for (name, uuid) in [("personal", "aaa"), ("work", "ccc")] {
        let dir = root.appendingPathComponent(".claude-accounts/\(name)", isDirectory: true)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try! Data("\(uuid)\n".utf8).write(to: dir.appendingPathComponent("account"))
    }
    let configDir = root.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    try! fm.createDirectory(at: configDir, withIntermediateDirectories: true)
    try! Data(#"{"lastKnownAccountUuid":"ccc"}"#.utf8).write(to: configDir.appendingPathComponent("config.json"))
    try! Data(#"{"oauthAccount":{"accountUuid":"aaa","emailAddress":"me@example.com"}}"#.utf8).write(to: root.appendingPathComponent(".claude.json"))
    let tag = AccountTag.current(home: root)
    expect(tag == AccountTag(app: "work", code: "personal") && tag?.mismatch == true, "saved names are used and a mismatch is seen, got \(String(describing: tag))")
    try! Data(#"{"oauthAccount":{"accountUuid":"zzz9999999","emailAddress":"pat@example.com"}}"#.utf8).write(to: root.appendingPathComponent(".claude.json"))
    expect(AccountTag.current(home: root)?.code == "pat", "an unsaved account falls back to its email name")
    expect(AccountTag.current(home: scratch.appendingPathComponent("nobody")) == nil, "no tag with no files")

    // Usual times, in a fixed time zone.
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Chicago")!
    let day0 = cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!
    func at(_ day: Int, _ h: Int, _ m: Int) -> Date { cal.date(byAdding: .minute, value: day * 1440 + h * 60 + m, to: day0)! }
    let now = at(20, 9, 0)
    let afternoon = [at(10, 14, 50), at(12, 15, 10), at(15, 15, 0), at(16, 15, 20)]
    expect(LimitTimes.usual(afternoon, now: now, calendar: cal) == [15 * 60 + 5], "four afternoons near 3 PM average to 3:05, got \(LimitTimes.usual(afternoon, now: now, calendar: cal))")
    expect(LimitTimes.usual(Array(afternoon.prefix(2)), now: now, calendar: cal).isEmpty, "two days is not yet usual")
    expect(LimitTimes.usual([at(3, 15, 0), at(3, 15, 30), at(3, 14, 45)], now: now, calendar: cal).isEmpty, "three hits on one day are one day")
    let late = [at(5, 23, 40), at(6, 0, 20), at(8, 0, 0)]
    expect(LimitTimes.usual(late, now: now, calendar: cal) == [0], "a cluster across midnight centres on midnight, got \(LimitTimes.usual(late, now: now, calendar: cal))")
    expect(LimitTimes.usual(afternoon + late, now: now, calendar: cal) == [0, 15 * 60 + 5], "two usual times, earliest first")
    expect(LimitTimes.usual(afternoon, now: at(60, 9, 0), calendar: cal).isEmpty, "hits older than four weeks don't count")
    let allHours = (0..<24).map { at($0, ($0 * 5) % 24, 0) }   // one limit a day, each at a different hour
    expect(LimitTimes.usual(allHours, now: at(25, 0, 0), calendar: cal).isEmpty,
           "3 of 24 limit days near any hour is under a quarter: no usual time")

    // The heads-up window: up to an hour before a usual time, today or tomorrow.
    expect(LimitTimes.upcoming([15 * 60], now: at(20, 14, 10), calendar: cal) == at(20, 15, 0), "50 minutes before 3 PM is in the window")
    expect(LimitTimes.upcoming([15 * 60], now: at(20, 13, 30), calendar: cal) == nil, "90 minutes before is too early")
    expect(LimitTimes.upcoming([15 * 60], now: at(20, 15, 1), calendar: cal) == nil, "just after is past")
    expect(LimitTimes.upcoming([10], now: at(20, 23, 30), calendar: cal) == at(21, 0, 10), "a usual time just after midnight is tomorrow's")

    // The log: dedup, account tagging, four-week window.
    var log = LimitLog()
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    func lim(_ ago: TimeInterval, resetsIn: TimeInterval = 600) -> UsageLimit {
        UsageLimit(hitAt: t.addingTimeInterval(-ago), resetsAt: t.addingTimeInterval(-ago + resetsIn))
    }
    log.record([lim(3600), lim(300), lim(240)], account: "personal", now: t)
    expect(log.hits.count == 2, "hits minutes apart are one hit, got \(log.hits.count)")
    expect(log.hits[0].account == nil && log.hits[1].account == "personal", "only a recent hit is tagged with the account seen now")
    log.record([lim(3600)], account: "work", now: t)
    expect(log.hits.count == 2, "a hit seen again is not added twice")
    var retries = LimitLog()
    retries.record([lim(4 * 3600, resetsIn: 3 * 3600), lim(3 * 3600), lim(2 * 3600 + 60), lim(3600)], account: nil, now: t)
    expect(retries.hits.count == 2, "retries before the reset are the same limit; one after it is new, got \(retries.hits.count)")
    log.hits.append(LimitLog.Hit(at: t.timeIntervalSince1970 - 100, account: "work"))
    expect(log.dates(for: "personal").count == 2 && log.dates(for: "work").count == 2, "each account counts its own hits and the untagged ones")
    log.record([], account: nil, now: t.addingTimeInterval(LimitLog.keep))
    expect(log.hits.isEmpty, "hits past four weeks are dropped")

    // Backfill reads session limits from old transcripts, not weekly ones.
    let projects = scratch.appendingPathComponent("limit-projects/p", isDirectory: true)
    try! fm.createDirectory(at: projects, withIntermediateDirectories: true)
    let lines = [
        #"{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","timestamp":"2026-11-01T20:00:00.000Z","message":{"content":[{"type":"text","text":"You've hit your session limit · resets 7pm (America/Chicago)"}]}}"#,
        #"{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","timestamp":"2026-11-02T20:00:00.000Z","message":{"content":[{"type":"text","text":"You've hit your weekly limit · resets Nov 5, 7pm (America/Chicago)"}]}}"#,
        #"{"type":"user","timestamp":"2026-11-02T20:01:00.000Z","message":{"content":"rate_limit is a word"}}"#,
    ]
    try! Data(lines.joined(separator: "\n").utf8).write(to: projects.appendingPathComponent("a.jsonl"))
    let older = LimitKeeper.olderHits(in: projects.deletingLastPathComponent(), now: Date())
    expect(older.count == 1 && older.first?.hitAt == UsageScanner.parseDate("2026-11-01T20:00:00.000Z"), "one session limit backfilled, got \(older)")
}

// MARK: auto-continue safety rules (Tests/ContinueTests.swift), on the main actor with a fake clock
var continueTestsDone = false
Task { @MainActor in await continueTests(); continueTestsDone = true }
while !continueTestsDone { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

print(failures == 0 ? "all \(checks) checks passed" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
