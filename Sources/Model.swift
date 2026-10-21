import AppKit
import Foundation
import os

/// Buddy's log: the system log (subsystem llc.purplelink.Buddy) and a small file,
/// ~/Library/Logs/Buddy/buddy.log, for Macs where the system log cannot be read.
/// The file is cut over to buddy.1.log at 512 KB.
enum Log {
    private static let logger = Logger(subsystem: "llc.purplelink.Buddy", category: "Buddy")
    private static let queue = DispatchQueue(label: "llc.purplelink.Buddy.log", qos: .utility)
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Buddy/buddy.log")

    static func note(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        let line = "\(stamp) \(message)\n"
        queue.async { append(line) }
    }

    private static func append(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > 512 * 1024 {
            let old = fileURL.deletingLastPathComponent().appendingPathComponent("buddy.1.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: fileURL, to: old)
        }
        if let handle = FileHandle(forWritingAtPath: fileURL.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: fileURL)
        }
    }
}

enum Mood: Int, Comparable {
    /// `paused`: stopped by a usage limit, waiting for it to reset.
    case idle, paused, done, working, attention

    static func < (a: Mood, b: Mood) -> Bool { a.rawValue < b.rawValue }
}

/// Where a session runs, so a click can jump straight to it.
struct Host: Equatable {
    var bundleID = ""
    /// The Claude app's own id for the chat (local_…), from CLAUDE_CODE_HOST_SESSION_ID.
    var desktopSessionID = ""
    /// The terminal device, e.g. "ttys003", for sessions in Terminal or iTerm2.
    var tty = ""
}

enum PauseReason { case limit, connection }

struct Session: Identifiable {
    let id: String
    var project: String
    var cwd = ""
    var prompt = ""
    var activity = "Ready"
    var mood = Mood.idle
    var attentionText = ""
    /// You have seen the current "needs you" or "finished" state (clicked or hovered).
    var acknowledged = false
    var host = Host()
    var transcriptPath = ""
    var turnStarted: Date?
    var updated = Date()
    /// The Claude app's title for the chat ("Coucou tool installation"), when it has one.
    var title = ""
    var titleChecked = Date.distantPast
    /// Cleared by a click or swipe; comes back when something new happens in the session.
    var hidden = false
    /// When the usage limit that paused this session resets.
    var limitResetsAt: Date?
    /// Found by scanning transcripts (paused before Buddy was listening), not by a live event.
    var fromScan = false
    /// Why a paused session stopped: a usage limit, or a dropped connection.
    var pauseReason = PauseReason.limit
    /// Automatic retries since the connection dropped (capped, so Buddy never loops).
    var retries = 0
    /// Times Auto typed "continue" into this chat for its current limit, and when it last did.
    var continueAttempts = 0
    var lastContinueAttempt: Date?

    var name: String { title.isEmpty ? project : title }
}

/// One Claude Code hook payload, as written by buddy-hook: a header line
/// "bundle id \t desktop session id \t tty", then the JSON Claude sent.
struct HookEvent {
    let host: Host
    let json: [String: Any]
    let date: Date

    init?(data: Data, date: Date) {
        guard let newline = data.firstIndex(of: 0x0A),
              let obj = try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...]),
              let json = obj as? [String: Any] else { return nil }
        let fields = String(decoding: data[..<newline], as: UTF8.self)
            .split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        func field(_ i: Int) -> String { i < fields.count ? fields[i] : "" }
        host = Host(bundleID: field(0), desktopSessionID: field(1), tty: field(2))
        self.json = json
        self.date = date
    }

    var name: String { json["hook_event_name"] as? String ?? "" }
    var sessionID: String { json["session_id"] as? String ?? "" }
    var cwd: String { json["cwd"] as? String ?? "" }
    var tool: String { json["tool_name"] as? String ?? "" }
    var input: [String: Any] { json["tool_input"] as? [String: Any] ?? [:] }
}

@MainActor
final class Store: ObservableObject {
    /// How long the pill stays open on its own when a session needs you, then just the badge.
    static let attentionPeek: TimeInterval = 20
    static let donePeek: TimeInterval = 4
    /// A finished session nobody looked at stops showing its green check after this.
    static let unseenDoneLimit: TimeInterval = 20 * 60

    @Published private(set) var sessions: [String: Session] = [:]
    /// The session the pill has opened itself for, if any.
    @Published private(set) var peek: String?

    private let defaults: UserDefaults
    private let sound: (String) -> Void
    private let now: () -> Date
    private let titles: ChatTitles
    private var peekTask: Task<Void, Never>?
    private var limitTask: Task<Void, Never>?
    /// Called with the sessions still paused a while after the limit reset (manual: false)
    /// or by "Continue now" (manual: true); the app types "continue" into them.
    var onContinue: (([Session], _ manual: Bool) -> Void)?
    /// Called with chats a dropped connection stopped, when it is time to retry them.
    var onRetry: (([Session]) -> Void)?
    /// Called when a live session stops on a connection error (the app may retry soon).
    var onConnectionLost: (() -> Void)?
    /// What the continue run is doing, shown in the limit banner.
    @Published var continueStatus: String?
    private var watchdog: Timer?

    init(defaults: UserDefaults = .standard,
         sound: @escaping (String) -> Void = { NSSound(named: $0)?.play() },
         now: @escaping () -> Date = Date.init,
         titles: ChatTitles = ChatTitles()) {
        self.defaults = defaults
        self.sound = sound
        self.now = now
        self.titles = titles
        migrateSoundSetting()
    }

    /// Sound when a chat needs you ("Ping") and when one finishes ("Glass"), set separately.
    var soundForAttention: Bool {
        get { !defaults.bool(forKey: "muteAttention") }
        set { defaults.set(!newValue, forKey: "muteAttention"); objectWillChange.send() }
    }
    var soundForDone: Bool {
        get { !defaults.bool(forKey: "muteDone") }
        set { defaults.set(!newValue, forKey: "muteDone"); objectWillChange.send() }
    }

    /// Buddy retries chats a dropped connection stopped, once you are back online.
    var retryConnectionsOn: Bool {
        get { !defaults.bool(forKey: "noConnectionRetry") }
        set { defaults.set(!newValue, forKey: "noConnectionRetry"); objectWillChange.send() }
    }

    /// Before 0.4 one "muted" switch silenced both sounds; carry it over once.
    private func migrateSoundSetting() {
        guard defaults.bool(forKey: "muted") else { return }
        defaults.set(true, forKey: "muteAttention")
        defaults.set(true, forKey: "muteDone")
        defaults.removeObject(forKey: "muted")
    }

    /// Buddy's backup for Claude Code's own auto-continue: type "continue" into chats
    /// still paused a few minutes after the limit resets.
    var autoContinueOn: Bool {
        get { defaults.bool(forKey: "autoTypeContinue") }
        set { defaults.set(newValue, forKey: "autoTypeContinue"); objectWillChange.send(); scheduleLimitTimers() }
    }

    /// Sessions in the list: everything not cleared by a click or swipe.
    private var visible: [Session] { sessions.values.filter { !$0.hidden } }

    var ordered: [Session] {
        visible.sorted { (rank($0), $0.updated) > (rank($1), $1.updated) }
    }

    /// List order by color: orange (needs you), green (finished, waiting on your reply),
    /// blue (working), purple (paused), then idle. Green stays above blue after you have
    /// looked at it: hovering the notch marks it seen, but it still waits on you.
    private func rank(_ s: Session) -> Int {
        switch s.mood {
        case .attention: return 4
        case .done: return 3
        case .working: return 2
        case .paused: return 1
        case .idle: return 0
        }
    }

    var attentionCount: Int { visible.filter { $0.mood == .attention }.count }
    var workingCount: Int { visible.filter { $0.mood == .working }.count }
    var unseenDoneCount: Int { visible.filter { $0.mood == .done && !$0.acknowledged }.count }

    /// Every session paused by a usage limit, including ones cleared from the list.
    var pausedSessions: [Session] { sessions.values.filter { $0.mood == .paused && $0.pauseReason == .limit } }

    /// Chats a dropped connection stopped; Buddy retries them when the network is back.
    var disconnectedSessions: [Session] {
        sessions.values.filter { $0.mood == .paused && $0.pauseReason == .connection }
    }

    /// The reset Buddy is counting down to (one account, so one limit for every chat).
    /// The countdown target: the next reset still to come, or the latest one once all have passed.
    /// Chats paused together can reset at different times, and each is continued at its own.
    var limitResetsAt: Date? {
        let resets = pausedSessions.compactMap(\.limitResetsAt)
        return resets.filter { $0 > now() }.min() ?? resets.max()
    }

    /// Worth showing the collapsed pill for.
    var hasNews: Bool {
        attentionCount + workingCount + unseenDoneCount > 0 || !pausedSessions.isEmpty || !disconnectedSessions.isEmpty
    }

    var overallMood: Mood {
        visible.filter { $0.mood != .done || !$0.acknowledged }.map(\.mood).max() ?? .idle
    }

    func apply(_ events: [HookEvent]) {
        for e in events { apply(e) }
        expire()
        updateWatchdog()
    }

    private func apply(_ e: HookEvent) {
        guard !e.sessionID.isEmpty else { return }
        if e.name == "SessionEnd" { remove(e.sessionID); return }

        // Replayed events (left in the inbox from before launch) update state quietly.
        let live = now().timeIntervalSince(e.date) < 5
        // The hook trims PostToolUse to a session id, too little to introduce a session.
        if sessions[e.sessionID] == nil, e.name == "PostToolUse" { return }
        var s = sessions[e.sessionID] ?? Session(id: e.sessionID, project: Self.project(e.cwd), cwd: e.cwd)
        s.fromScan = false
        if s.cwd.isEmpty, !e.cwd.isEmpty { s.cwd = e.cwd; s.project = Self.project(e.cwd) }
        if !e.host.bundleID.isEmpty { s.host = e.host }
        if let path = e.json["transcript_path"] as? String, !path.isEmpty { s.transcriptPath = path }
        s.updated = e.date
        let before = s.mood

        switch e.name {
        case "UserPromptSubmit":
            s.retries = 0
            // Prompts that are only app-injected <system-reminder> blocks keep the last real one.
            let prompt = Self.oneLine(Self.withoutTags(e.json["prompt"] as? String ?? ""), 60)
            if !prompt.isEmpty { s.prompt = prompt }
            if s.mood != .working || s.turnStarted == nil { s.turnStarted = e.date }
            s.activity = "Thinking"
            s.mood = .working
        case "PreToolUse" where e.tool == "AskUserQuestion":
            flag(&s, "Has a question for you")
        case "PreToolUse" where e.tool == "ExitPlanMode":
            flag(&s, "Has a plan for you to review")
        case "PreToolUse":
            s.activity = Self.describe(e.tool, e.input)
            s.mood = .working
        case "PostToolUse":
            // The tool ran, so whatever was waiting on you has been answered.
            if s.mood == .attention { s.mood = .working; s.activity = "Thinking" }
        case "PermissionRequest":
            flag(&s, "Needs your OK: " + Self.describe(e.tool, e.input))
        case "Notification":
            let kind = e.json["notification_type"] as? String ?? ""
            // idle_prompt repeats "waiting for input" after Stop already said so.
            guard kind != "auth_success", kind != "idle_prompt" else { break }
            if s.mood != .attention {
                flag(&s, Self.oneLine(e.json["message"], 80, fallback: "Needs your attention"))
            }
        case "StopFailure" where e.json["error"] as? String == "rate_limit":
            // "You've hit your session limit · resets 3:30pm (America/Chicago)"
            let message = e.json["last_assistant_message"] as? String ?? ""
            s.mood = .paused
            s.pauseReason = .limit
            s.limitResetsAt = ResetTime.parse(message, after: e.date)
            s.activity = "Paused by your usage limit"
            s.turnStarted = nil
            // A new limit starts a new count, unless Buddy typed into this chat moments ago
            // (the limit had not really lifted yet): then the tries keep counting, so Auto
            // can never loop.
            let typedMomentsAgo = s.lastContinueAttempt.map { e.date.timeIntervalSince($0) < 15 * 60 } ?? false
            if !typedMomentsAgo {
                s.continueAttempts = 0
                s.lastContinueAttempt = nil
            }
            if live {
                Log.note("limit paused \(s.name), resets \(s.limitResetsAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "at an unknown time")")
            }
        case "StopFailure" where Self.isConnectionError(e.json["error"] as? String,
                                                        e.json["last_assistant_message"] as? String ?? ""):
            // "Can't reach the API server", "Connection lost mid-response", "went to sleep"
            s.mood = .paused
            s.pauseReason = .connection
            s.activity = Self.connectionLostText
            s.turnStarted = nil
        case "StopFailure":
            let error = (e.json["error"] as? String ?? "error").replacingOccurrences(of: "_", with: " ")
            flag(&s, "Stopped by an API error (\(error))")
            s.turnStarted = nil
        case "Stop":
            s.mood = .done
            s.acknowledged = false
            s.activity = s.turnStarted.map { "Finished in \(Self.duration(e.date.timeIntervalSince($0)))" } ?? "Finished"
            s.turnStarted = nil
        default:
            break
        }

        // Something new brings a cleared session back.
        if e.name == "UserPromptSubmit" || (s.mood != before && (s.mood == .attention || s.mood == .done)) {
            s.hidden = false
        }
        refreshTitle(&s, soon: ["SessionStart", "UserPromptSubmit", "Stop"].contains(e.name))

        if s.mood != .paused { s.limitResetsAt = nil }

        sessions[s.id] = s
        if live, s.mood == .paused, s.pauseReason == .connection, before != .paused {
            onConnectionLost?()  // after saving, so the app sees this chat as stopped
        }
        if peek == s.id, s.mood != before { endPeek() }
        if s.mood == .paused || before == .paused { scheduleLimitTimers() }
        guard live, s.mood != before else { return }
        if s.mood == .attention {
            if soundForAttention { sound("Ping") }
            startPeek(s.id, for: Self.attentionPeek)
        }
        if s.mood == .done {
            if soundForDone { sound("Glass") }
            startPeek(s.id, for: Self.donePeek)
        }
    }

    /// The app names a chat after its first turn and may rename it, so look again at turn
    /// boundaries (at most every few seconds) and otherwise only while there is no title.
    private func refreshTitle(_ s: inout Session, soon: Bool) {
        guard !s.host.desktopSessionID.isEmpty, soon || s.title.isEmpty,
              now().timeIntervalSince(s.titleChecked) > (soon ? 3 : 20) else { return }
        s.titleChecked = now()
        if let title = titles.title(for: s.host.desktopSessionID) { s.title = title }
    }

    private func flag(_ s: inout Session, _ text: String) {
        if s.mood != .attention { s.acknowledged = false }
        s.mood = .attention
        s.attentionText = text
    }

    private func startPeek(_ id: String, for seconds: TimeInterval) {
        peek = id
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.peek = nil
        }
    }

    private func endPeek() {
        peekTask?.cancel()
        peek = nil
    }


    private func remove(_ id: String) {
        sessions[id] = nil
        if peek == id { endPeek() }
    }

    /// Drop sessions that went quiet (closed terminals never send SessionEnd) and let
    /// old unseen finishes stop asking for attention.
    func expire() {
        let now = now()
        sessions = sessions.filter { _, s in
            let quiet = now.timeIntervalSince(s.updated)
            switch s.mood {
            case .working, .attention: return quiet < 2 * 3600
            case .done, .idle: return quiet < 45 * 60
            // Kept until well after the reset, so it can still be continued.
            // Kept as long as the scan looks back, so old pauses can still be continued.
            case .paused: return quiet < PausedScan.lookBack || (s.limitResetsAt ?? .distantPast) > now
            }
        }
        for (id, s) in sessions where s.mood == .done && !s.acknowledged
            && now.timeIntervalSince(s.updated) > Self.unseenDoneLimit {
            sessions[id]?.acknowledged = true
        }
    }

    // MARK: - Stuck sessions

    /// Esc sends no Stop event, so a busy session that goes quiet gets its transcript checked.
    /// Runs only while some session is working or waiting.
    private func updateWatchdog() {
        let needed = sessions.values.contains { $0.mood >= .working }
        if needed, watchdog == nil {
            let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkQuietSessions() }
            }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            watchdog = timer
        } else if !needed {
            watchdog?.invalidate()
            watchdog = nil
        }
    }

    func checkQuietSessions() {
        let now = now()
        for var s in sessions.values where s.mood >= .working && now.timeIntervalSince(s.updated) > 10 {
            if Transcript.wasInterrupted(at: s.transcriptPath) {
                s.activity = "Interrupted"
            } else if s.mood == .working,
                      now.timeIntervalSince(max(s.updated, Transcript.modified(s.transcriptPath) ?? s.updated)) > 30 * 60 {
                s.activity = "No activity for 30 min"
            } else {
                continue
            }
            s.mood = .idle
            s.turnStarted = nil
            s.acknowledged = true
            sessions[s.id] = s
            if peek == s.id { endPeek() }
        }
        updateWatchdog()
    }

    // MARK: - Actions

    /// Hovering the pill counts as having seen what finished.
    func markFinishedSeen() {
        for (id, s) in sessions where s.mood == .done && !s.acknowledged {
            sessions[id]?.acknowledged = true
        }
    }

    func clearFinished() {
        sessions = sessions.filter { $0.value.mood >= .working || $0.value.mood == .paused }
    }

    /// Clears a session from the list until something new happens in it.
    func dismiss(_ id: String) {
        guard sessions[id] != nil else { return }
        sessions[id]?.hidden = true
        sessions[id]?.acknowledged = true
        if peek == id { endPeek() }
    }

    /// Jump to the session's chat or terminal tab, and clear it from the list.
    func open(_ id: String) {
        guard let s = sessions[id] else { return }
        dismiss(id)
        Jump.target(host: s.host, cwd: s.cwd).perform()
    }

    // MARK: - Usage limits

    /// How long after a chat's own reset Auto types "continue". Claude Code's built-in
    /// auto-continue never resumed a Claude app chat in the transcripts checked on
    /// 2026-10-20, so those get one grace minute. Terminal sessions, where the built-in can
    /// act (1 to 5 minutes after the reset), get six.
    nonisolated static func continueDelay(for host: Host) -> TimeInterval {
        host.bundleID == Jump.claudeApp ? 60 : 6 * 60
    }
    /// Try again if a chat is still paused this long after Auto typed into it.
    static let continueRetryGap: TimeInterval = 3 * 60
    static let maxContinueAttempts = 3
    /// Auto leaves alone chats whose limit reset longer ago than this (likely abandoned).
    static let autoContinueWindow: TimeInterval = 12 * 3600

    /// When Auto should next act on this chat, or nil when it should not.
    private func autoDue(_ s: Session) -> Date? {
        guard let reset = s.limitResetsAt, s.continueAttempts < Self.maxContinueAttempts else { return nil }
        let first = reset.addingTimeInterval(Self.continueDelay(for: s.host))
        guard now().timeIntervalSince(first) < Self.autoContinueWindow else { return nil }
        guard let last = s.lastContinueAttempt else { return first }
        return max(first, last.addingTimeInterval(Self.continueRetryGap))
    }

    /// When Auto will next type "continue", if it is on.
    var autoContinueAt: Date? {
        guard autoContinueOn else { return nil }
        return pausedSessions.compactMap(autoDue).min()
    }

    /// Some paused chat's limit has reset (Continue now can act on it).
    var limitHasReset: Bool { pausedSessions.contains { ($0.limitResetsAt ?? .distantPast) <= now() } }

    /// Wakes at the next reset (to refresh the banner) or the next Auto action, whichever
    /// comes first, acts, and schedules itself again.
    private func scheduleLimitTimers() {
        limitTask?.cancel()
        let now = now()
        var wakes = pausedSessions.compactMap(\.limitResetsAt).filter { $0 > now }
        if let due = autoContinueAt { wakes.append(due) }
        guard let next = wakes.min() else { return }
        limitTask = Task { [weak self] in
            let wait = next.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self else { return }
            self.objectWillChange.send()
            self.runAutoContinue()
            self.scheduleLimitTimers()
        }
    }

    /// Hands Auto the paused chats that are due (their own reset has passed, or a retry is
    /// due) and counts the attempt. Called by the timer; tests call it directly.
    func runAutoContinue() {
        guard autoContinueOn else { return }
        let now = now()
        var due: [Session] = []
        for var s in pausedSessions {
            guard let at = autoDue(s), at <= now else { continue }
            s.continueAttempts += 1
            s.lastContinueAttempt = now
            sessions[s.id] = s
            due.append(s)
        }
        guard !due.isEmpty else { return }
        Log.note("auto-continue due: " + due.map { "\($0.name) (try \($0.continueAttempts))" }.joined(separator: ", "))
        onContinue?(due, false)
    }

    /// Merges a transcript scan: adds chats paused before Buddy was listening, and drops
    /// scanned pauses that are no longer paused (continued or archived). Anything Buddy has
    /// heard about live is left alone.
    func adoptScan(_ found: [Session]) {
        let ids = Set(found.map(\.id))
        for (id, s) in sessions where s.fromScan && !ids.contains(id) {
            sessions[id] = nil
        }
        for f in found where sessions[f.id] == nil || sessions[f.id]?.fromScan == true {
            var adopted = f
            if let old = sessions[f.id] {
                adopted.hidden = old.hidden
                // A rescan of the same pause keeps Auto's count, so retries stay capped.
                if old.limitResetsAt == f.limitResetsAt {
                    adopted.continueAttempts = old.continueAttempts
                    adopted.lastContinueAttempt = old.lastContinueAttempt
                }
            } else if f.mood == .paused, f.pauseReason == .limit {
                Log.note("found paused chat \(f.name), resets \(f.limitResetsAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "at an unknown time")")
            }
            sessions[f.id] = adopted
        }
        expire()
        scheduleLimitTimers()
    }

    static let maxRetries = 3
    nonisolated static let connectionLostText = "Connection lost · retrying when you're back online"

    /// A server_error (or unknown error) whose message says the network dropped, as
    /// Claude Code words it: "Can't reach the API server ... (ENOTFOUND)", "Connection lost
    /// mid-response", "Your computer went to sleep mid-response".
    nonisolated static func isConnectionError(_ error: String?, _ message: String) -> Bool {
        guard error == "server_error" || error == "unknown" || error == nil else { return false }
        let pattern = #"(?i)can'?t reach|cannot reach|connection (lost|reset|refused|closed|error|went idle)|went to sleep|network|internet|offline|ENOTFOUND|ECONNRESET|ECONNREFUSED|ETIMEDOUT|EAI_AGAIN|socket hang up|timed out"#
        return message.range(of: pattern, options: .regularExpression) != nil
    }

    /// Hands chats a dropped connection stopped to the app to retry. `fresh` (the network
    /// came back, or the Mac woke) restarts the attempt count; otherwise each chat gets at
    /// most `maxRetries` tries.
    func retryDisconnected(fresh: Bool) {
        guard retryConnectionsOn else { return }
        var due: [Session] = []
        for var s in disconnectedSessions {
            if fresh { s.retries = 0 }
            guard s.retries < Self.maxRetries else { continue }
            s.retries += 1
            sessions[s.id] = s
            due.append(s)
        }
        if !due.isEmpty { onRetry?(due) }
    }

    /// Hands every still-paused session to the typer ("Continue now", or the timer).
    func continuePaused(manual: Bool = true) {
        let paused = pausedSessions
        if !paused.isEmpty { onContinue?(paused, manual) }
    }

    /// Clicking the pill itself goes to whatever matters most.
    func openTop() {
        if let top = ordered.first { open(top.id) }
    }

    // MARK: - Wording

    /// "Acme", or "Acme › login-fix" for a git worktree session.
    nonisolated static func project(_ cwd: String) -> String {
        let parts = cwd.split(separator: "/").map(String.init)
        if let i = parts.lastIndex(of: "worktrees"), i >= 2, parts[i - 1] == ".claude", i + 1 < parts.count {
            return "\(parts[i - 2]) › \(parts[i + 1])"
        }
        if let i = parts.lastIndex(of: "_worktrees"), i + 2 < parts.count {
            return "\(parts[i + 1]) › \(parts[i + 2])"
        }
        return parts.last ?? "Claude"
    }

    /// The collapsed pill's countdown: "1h 14m" for an hour or more, "14:25" under an hour.
    nonisolated static func shortCountdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        if s >= 3600 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

    /// Drops <tag>…</tag> blocks (system reminders, pasted content) from a prompt.
    nonisolated static func withoutTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"<([A-Za-z_-]+)[^>]*>[\s\S]*?</\1>"#, with: " ",
                                  options: .regularExpression)
    }

    nonisolated static func oneLine(_ value: Any?, _ limit: Int, fallback: String = "") -> String {
        let text = (value as? String ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if text.isEmpty { return fallback }
        return text.count > limit ? text.prefix(limit - 1) + "…" : text
    }

    nonisolated static func describe(_ tool: String, _ input: [String: Any]) -> String {
        func str(_ key: String) -> String { input[key] as? String ?? "" }
        func file(_ key: String = "file_path") -> String { (str(key) as NSString).lastPathComponent }

        switch tool {
        case "Bash":
            let what = oneLine(input["description"], 60)
            return what.isEmpty ? "Running " + oneLine(input["command"], 50) : what
        case "Read": return "Reading \(file())"
        case "Edit", "MultiEdit": return "Editing \(file())"
        case "Write": return "Writing \(file())"
        case "NotebookEdit": return "Editing \(file("notebook_path"))"
        case "Grep": return "Searching for “\(oneLine(input["pattern"], 30))”"
        case "Glob": return "Looking for \(oneLine(input["pattern"], 30))"
        case "WebFetch": return "Reading \(URL(string: str("url"))?.host() ?? "a web page")"
        case "WebSearch": return "Searching the web for “\(oneLine(input["query"], 30))”"
        case "Task", "Agent": return "Delegating: " + oneLine(input["description"], 45, fallback: "a subtask")
        case "TodoWrite", "mcp__ccd_turn__update_plan": return "Updating its plan"
        case "Skill": return "Using the \(str("skill")) skill"
        default:
            // mcp__server__do_thing → "Using do thing"
            let short = tool.components(separatedBy: "__").last ?? tool
            return "Using " + short.replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// Reads only the end of a session transcript, to spot an interrupt or a usage-limit pause.
enum Transcript {
    static let marker = "[Request interrupted by user"

    static func modified(_ path: String) -> Date? {
        guard !path.isEmpty else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// True when the newest real entry is the interrupt marker Claude Code writes after Esc
    /// (bookkeeping lines may follow it; a newer assistant message means Claude went on).
    static func wasInterrupted(at path: String, tailBytes: UInt64 = 64 * 1024) -> Bool {
        guard !path.isEmpty, let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        let start = size > tailBytes ? size - tailBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return false }

        var lines = data.split(separator: 0x0A)
        if start > 0, !lines.isEmpty { lines.removeFirst() }  // partial line
        for line in lines.reversed() {
            let text = String(decoding: line, as: UTF8.self)
            let mentionsAssistant = text.contains("\"type\":\"assistant\"")
            let mentionsMarker = text.contains(marker)
            guard mentionsAssistant || mentionsMarker,
                  let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let type = entry["type"] as? String
            if type == "assistant" { return false }
            if type == "user", isMarker(entry) { return true }
        }
        return false
    }

    /// The error, its message and its time, when the newest real entry is a usage-limit error
    /// or a dropped-connection error (bookkeeping such as cost-state may follow it; a newer
    /// message means the chat moved on).
    static func stoppedEntry(at path: String, tailBytes: UInt64 = 64 * 1024) -> (error: String, message: String, date: Date)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > tailBytes ? size - tailBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: 0x0A)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = entry["type"] as? String, type == "user" || type == "assistant",
                  entry["isMeta"] as? Bool != true else { continue }
            guard type == "assistant", entry["isApiErrorMessage"] as? Bool == true,
                  let error = entry["error"] as? String else { return nil }
            let parts = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
            guard error == "rate_limit" || Store.isConnectionError(error, text) else { return nil }
            let date = (entry["timestamp"] as? String).flatMap(parseTimestamp) ?? Date()
            return (error, text, date)
        }
        return nil
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    private static func isMarker(_ entry: [String: Any]) -> Bool {
        let content = (entry["message"] as? [String: Any])?["content"]
        if let text = content as? String { return text.hasPrefix(marker) }
        if let parts = content as? [[String: Any]], parts.count == 1 {
            return (parts[0]["text"] as? String)?.hasPrefix(marker) == true
        }
        return false
    }
}

/// Reads chat titles from the Claude app's per-chat files. Only the first 16 KB is read: the
/// title sits in the first few KB, and the rest of the file is a large tool list.
final class ChatTitles {
    let root: URL
    private var paths: [String: URL] = [:]

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)) {
        self.root = root
    }

    func title(for id: String) -> String? {
        guard id.range(of: #"^local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil,
              let url = paths[id] ?? find(id) else { return nil }
        guard let handle = FileHandle(forReadingAtPath: url.path) else { paths[id] = nil; return nil }
        paths[id] = url
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16 * 1024) else { return nil }
        let text = String(decoding: head, as: UTF8.self)
        guard let range = text.range(of: #""title":"((?:[^"\\]|\\.)*)""#, options: .regularExpression) else { return nil }
        let literal = Data(text[range].dropFirst(8).utf8)  // the quoted JSON string after "title":
        guard let title = (try? JSONSerialization.jsonObject(with: literal, options: .fragmentsAllowed)) as? String
        else { return nil }
        let line = Store.oneLine(title, 60)
        return line.isEmpty ? nil : line
    }

    /// <root>/<account>/<organization>/<id>.json
    private func find(_ id: String) -> URL? {
        let fm = FileManager.default
        for account in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                let file = org.appendingPathComponent(id + ".json")
                if fm.fileExists(atPath: file.path) { return file }
            }
        }
        return nil
    }
}

/// Row geometry shared by the list view, the window size and swipe hit-testing.
enum RowLayout {
    static let height: CGFloat = 46
    static let spacing: CGFloat = 2
    /// Rows visible before the list scrolls.
    static let visible = 6

    static func listHeight(rows: Int) -> CGFloat {
        CGFloat(max(1, min(rows, visible))) * (height + spacing)
    }

    /// Which row is under a point `y` below the top of the list, given how far it has scrolled.
    static func index(atDistanceIntoList y: CGFloat, scrolled: CGFloat, count: Int) -> Int? {
        guard y >= 0 else { return nil }
        let index = Int((y + scrolled) / (height + spacing))
        return index < count ? index : nil
    }
}

/// Reads the reset time out of Claude Code's limit message, e.g.
/// "You've hit your session limit · resets 3:30pm (America/Chicago)" or a weekly one with a
/// date ("resets Oct 20, 9am (America/Chicago)").
enum ResetTime {
    private static let pattern =
        #"resets\s+(?:([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2}),?\s+(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*([ap]m)\s*\(([^)]+)\)"#

    static func parse(_ message: String, after date: Date) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) else { return nil }
        func group(_ i: Int) -> String? {
            Range(m.range(at: i), in: message).map { String(message[$0]) }
        }
        guard let zoneName = group(6), let zone = TimeZone(identifier: zoneName.trimmingCharacters(in: .whitespaces)),
              var hour = group(3).flatMap(Int.init), (1...12).contains(hour) else { return nil }
        let minute = group(4).flatMap(Int.init) ?? 0
        let pm = group(5)?.lowercased() == "pm"
        hour = hour % 12 + (pm ? 12 : 0)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var parts = calendar.dateComponents([.year, .month, .day], from: date)
        parts.hour = hour
        parts.minute = minute
        if let monthName = group(1), let day = group(2).flatMap(Int.init) {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let month = months.firstIndex(of: monthName.lowercased()) else { return nil }
            parts.month = month + 1
            parts.day = day
            guard var result = calendar.date(from: parts) else { return nil }
            if result < date.addingTimeInterval(-86400) {  // "Jan 2" seen in late December
                result = calendar.date(byAdding: .year, value: 1, to: result) ?? result
            }
            return result
        }
        guard var result = calendar.date(from: parts) else { return nil }
        if result <= date.addingTimeInterval(-60) {  // "resets 1am" said at 11pm
            result = calendar.date(byAdding: .day, value: 1, to: result) ?? result
        }
        return result
    }
}

/// Finds Claude app chats that a usage limit paused before Buddy was listening: recent,
/// unarchived chats whose transcript ends on a limit message. Transcripts are re-read only
/// when they change. Runs off the main thread; the app only ever uses it from one serial
/// queue, which is what makes the unchecked Sendable safe.
final class PausedScan: @unchecked Sendable {
    /// How far back to look; a weekly limit can pause a chat for days.
    static let lookBack: TimeInterval = 8 * 86400
    /// Connection drops older than this are left alone (they are not retried).
    static let connectionLookBack: TimeInterval = 6 * 3600

    let sessionsRoot: URL
    let projectsRoot: URL
    private var cache: [String: (modified: Date, pause: (error: String, message: String, date: Date)?)] = [:]

    init(sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true),
         projectsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)) {
        self.sessionsRoot = sessionsRoot
        self.projectsRoot = projectsRoot
    }

    func run(now: Date = Date()) -> [Session] {
        let fm = FileManager.default
        let projectDirs = (try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil)) ?? []
        var found: [Session] = []
        for file in chatFiles() {
            guard let modified = Self.modified(file), now.timeIntervalSince(modified) < Self.lookBack,
                  let head = try? FileHandle(forReadingFrom: file).read(upToCount: 16 * 1024) else { continue }
            let text = String(decoding: head, as: UTF8.self)
            guard !text.contains(#""isArchived":true"#),
                  let cli = Self.string("cliSessionId", in: text),
                  cli.range(of: #"^[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil,
                  let transcript = projectDirs.lazy.map({ $0.appendingPathComponent(cli + ".jsonl") })
                    .first(where: { fm.fileExists(atPath: $0.path) }),
                  let pause = pause(at: transcript) else { continue }

            let cwd = Self.string("cwd", in: text) ?? ""
            var s = Session(id: cli, project: Store.project(cwd), cwd: cwd)
            s.title = Self.string("title", in: text).map { Store.oneLine($0, 60) } ?? ""
            s.host = Host(bundleID: Jump.claudeApp, desktopSessionID: file.deletingPathExtension().lastPathComponent)
            s.transcriptPath = transcript.path
            s.mood = .paused
            if pause.error == "rate_limit" {
                s.activity = "Paused by your usage limit"
                s.limitResetsAt = ResetTime.parse(pause.message, after: pause.date)
            } else {
                // Only recent drops: never auto-retry a chat that stopped hours ago.
                guard now.timeIntervalSince(pause.date) < Self.connectionLookBack else { continue }
                s.pauseReason = .connection
                s.activity = Store.connectionLostText
            }
            s.updated = pause.date
            s.acknowledged = true
            s.fromScan = true
            found.append(s)
        }
        return found
    }

    private func pause(at transcript: URL) -> (error: String, message: String, date: Date)? {
        guard let modified = Self.modified(transcript) else { return nil }
        if let hit = cache[transcript.path], hit.modified == modified { return hit.pause }
        let pause = Transcript.stoppedEntry(at: transcript.path)
        cache[transcript.path] = (modified, pause)
        return pause
    }

    /// <root>/<account>/<organization>/local_*.json
    private func chatFiles() -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        for account in (try? fm.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                let chats = (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)) ?? []
                files += chats.filter { $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json" }
            }
        }
        return files
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// A top-level "key":"value" string from compact JSON, decoded.
    static func string(_ key: String, in text: String) -> String? {
        guard let range = text.range(of: "\"\(key)\":\"((?:[^\"\\\\]|\\\\.)*)\"", options: .regularExpression) else { return nil }
        let literal = Data(text[range].dropFirst(key.count + 3).utf8)
        return (try? JSONSerialization.jsonObject(with: literal, options: .fragmentsAllowed)) as? String
    }
}
