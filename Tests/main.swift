import Foundation

// Logic tests for Buddy. Run with ./build.sh test, which points HOME at a throwaway folder.
// Nothing here opens windows, plays sounds or switches apps: sounds and the clock are
// injected, and Jump is only asked for its target, never performed.

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

print(failures == 0 ? "all \(checks) checks passed" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
