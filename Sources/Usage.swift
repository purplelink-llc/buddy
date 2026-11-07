import AppKit
import Foundation

/// Plan usage shown at the top of Buddy's list: the 5-hour session window and, when exact,
/// the weekly window.
struct UsageReading: Equatable {
    struct Window: Equatable {
        var percent: Double
        var resetsAt: Date?
    }
    var session: Window?
    var week: Window?
    /// The separate weekly limit for Opus models, when the plan has one (exact usage only).
    var opusWeek: Window?
    /// True when the numbers come from Anthropic; false for Buddy's local estimate.
    var exact: Bool
    /// Why exact usage is unavailable right now, if it was asked for.
    var note: String?
    /// True when signing in to Claude Code again would fix it (Settings then offers Sign In).
    var needsSignIn = false
}

/// Which window the notch pill shows (docs/designs/weekly-usage-pace.md).
enum NotchWindow: String {
    case session, week
}

extension UsageReading {
    static let sessionLength: TimeInterval = 5 * 3600
    static let weekLength: TimeInterval = 7 * 24 * 3600

    /// The window the pill shows: the week only when it was chosen, the reading is exact, the week has a reset time,
    /// and no chat is paused by a limit (then the pill matches the limit countdown beside it). Otherwise the session.
    func shown(_ choice: NotchWindow, limitPaused: Bool) -> (window: Window, isWeek: Bool)? {
        if choice == .week, exact, !limitPaused, let w = week, w.resetsAt != nil { return (w, true) }
        return session.map { ($0, false) }
    }
}

/// Where a window ends up by its reset at the average rate so far, and when it would run out if that is first.
struct UsagePace: Equatable {
    /// "About 12% a day at an even pace to Sat 9 AM": what is left spread evenly over the days left (weekly windows).
    static func dailyBudget(percent: Double, resetsAt: Date?, now: Date, short: Bool = false) -> String? {
        guard let reset = resetsAt, reset > now, percent < 100 else { return nil }
        let days = reset.timeIntervalSince(now) / 86400
        guard days > 0.1 else { return nil }
        let perDay = Int(((100 - percent) / days).rounded())
        let when = reset.formatted(.dateTime.weekday(.abbreviated).hour())
        return short ? "\(perDay)% a day to \(when)" : "About \(perDay)% a day at an even pace to \(when)."
    }

    /// Percent of the limit used by the reset at this rate.
    let projected: Double
    /// When it would reach 100%, only if that comes before the reset; rounded to 5 minutes.
    let runsOutAt: Date?
    /// What the projection rests on: the time left (v2), or your usual hours (v3.1, the week only).
    enum Basis: Equatable { case time, habits }
    var basis: Basis = .time
    /// How far forecasts this far into a window have been off, in points (week by habits only).
    var band: Double? = nil

    /// nil when there is nothing honest to say: no reset or one already past, a reset that does not fit the window
    /// (stale or moved), under 3% used, already at the limit, or too early in the window for an average to mean
    /// anything (1 hour of a session, 24 hours of a week), since a heavy first stretch would project a false run-out.
    static func pace(percent: Double, resetsAt: Date?, length: TimeInterval, now: Date) -> UsagePace? {
        guard let reset = resetsAt, reset > now, percent >= 3, percent < 100 else { return nil }
        let start = reset.addingTimeInterval(-length)
        let elapsed = now.timeIntervalSince(start)
        let minimum: TimeInterval = length > UsageReading.sessionLength ? 24 * 3600 : 3600
        guard elapsed > 0, elapsed <= length, elapsed >= minimum else { return nil }
        let projected = percent * length / elapsed
        guard projected.rounded() > 100 else { return UsagePace(projected: projected, runsOutAt: nil) }
        let out = start.addingTimeInterval(elapsed * 100 / percent).timeIntervalSinceReferenceDate
        return UsagePace(projected: projected, runsOutAt: Date(timeIntervalSinceReferenceDate: (out / 300).rounded() * 300))
    }

    /// The hover sentence: "At this rate, 130% of the limit by the reset (Sat 9 AM); runs out around Thu 2:05 PM."
    func sentence(resetsAt: Date, weekly: Bool) -> String {
        let when: (Date) -> String = { weekly ? $0.formatted(.dateTime.weekday(.abbreviated).hour().minute())
                                              : $0.formatted(date: .omitted, time: .shortened) }
        let lead = basis == .habits ? "At your usual pace" : "At this rate"
        let number = band.map { b in b > 1 ? "\(Int((projected - b).rounded()))–\(Int((projected + b).rounded()))%" : nil } ?? nil
        let head = "\(lead), \(number ?? "\(Int(projected.rounded()))%") of the limit by the reset (\(when(resetsAt)))"
        let tail = basis == .habits ? " Learned from Claude on this Mac." : ""
        if let out = runsOutAt { return head + "; runs out around \(when(out))." + tail }
        return head + "; about \(max(0, 100 - Int(projected.rounded())))% left then." + tail
    }
}

/// One reply's cost in "weighted tokens", Buddy's unit for the local estimate.
struct UsageReply {
    let date: Date
    let weight: Double
}

/// A session limit Claude Code reported: when it hit and when it reset.
struct UsageLimit {
    let hitAt: Date
    let resetsAt: Date
}

/// Estimates session usage from this Mac's transcripts: each reply's tokens, weighted by
/// type and model, summed over the current 5-hour window, as a share of what the last few
/// session limits took. It sees only chats on this Mac.
enum UsageEstimate {
    static let window: TimeInterval = 5 * 3600

    /// Weighted cost of one reply, in the proportions Anthropic prices tokens: cache writes
    /// 1.25x input, cache reads 0.1x, output 5x; Opus-class models about 1.67x Sonnet, Haiku 0.33x.
    static func weight(model: String, input: Double, output: Double, cacheWrite: Double, cacheRead: Double) -> Double {
        let m = model.lowercased()
        let factor = m.contains("haiku") ? 0.33 : m.contains("sonnet") ? 1.0 : 1.67
        return factor * (input + 1.25 * cacheWrite + 0.1 * cacheRead + 5 * output)
    }

    /// What a full session window takes: the median weighted total of the last five limits
    /// (from the window's start to the moment the limit hit). Nil before any limit is seen.
    static func capacity(replies: [UsageReply], limits: [UsageLimit]) -> Double? {
        let totals = limits.sorted { $0.hitAt < $1.hitAt }.suffix(5).map { limit -> Double in
            let start = limit.resetsAt.addingTimeInterval(-window)
            return replies.filter { $0.date >= start && $0.date <= limit.hitAt }.reduce(0) { $0 + $1.weight }
        }.filter { $0 > 0 }.sorted()
        guard !totals.isEmpty else { return nil }
        return totals[totals.count / 2]
    }

    /// The 5-hour window that contains `now`: the one a pending limit names, or else the one
    /// that started with the first reply after the last known reset (windows chain from there).
    static func currentWindow(replies: [UsageReply], limits: [UsageLimit], now: Date) -> (start: Date, end: Date)? {
        if let pending = limits.filter({ $0.resetsAt > now && $0.hitAt <= now }).max(by: { $0.resetsAt < $1.resetsAt }) {
            return (pending.resetsAt.addingTimeInterval(-window), pending.resetsAt)
        }
        let anchor = limits.map(\.resetsAt).filter { $0 <= now }.max() ?? now.addingTimeInterval(-24 * 3600)
        let times = replies.map(\.date).filter { $0 >= anchor && $0 <= now }.sorted()
        guard var start = times.first else { return nil }
        while start.addingTimeInterval(window) <= now {
            guard let next = times.first(where: { $0 >= start.addingTimeInterval(window) }) else { return nil }
            start = next
        }
        return (start, start.addingTimeInterval(window))
    }

    static func reading(replies: [UsageReply], limits: [UsageLimit], now: Date) -> UsageReading {
        guard let capacity = capacity(replies: replies, limits: limits),
              let (start, end) = currentWindow(replies: replies, limits: limits, now: now) else {
            return UsageReading(session: nil, week: nil, exact: false, note: nil)
        }
        let used = replies.filter { $0.date >= start && $0.date <= now }.reduce(0) { $0 + $1.weight }
        return UsageReading(session: .init(percent: min(100, 100 * used / capacity), resetsAt: end), week: nil, exact: false)
    }
}

/// Reads replies and session limits from transcripts modified in the last three days.
/// Files are read incrementally (only new bytes after the first pass). Used from one
/// serial queue only, which is what makes the unchecked Sendable safe.
final class UsageScanner: @unchecked Sendable {
    static let history: TimeInterval = 3 * 86400

    let projectsRoot: URL
    private var offsets: [String: UInt64] = [:]
    private var replies: [String: UsageReply] = [:]   // by message id
    private var limits: [String: UsageLimit] = [:]    // by entry uuid or time

    init(projectsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)) {
        self.projectsRoot = projectsRoot
    }

    func scan(now: Date = Date()) -> UsageReading {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Self.history)
        let dirs = (try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modified >= cutoff else { continue }
                read(file)
            }
        }
        replies = replies.filter { $0.value.date >= cutoff }
        limits = limits.filter { $0.value.hitAt >= cutoff }
        return UsageEstimate.reading(replies: Array(replies.values), limits: Array(limits.values), now: now)
    }

    private func read(_ file: URL) {
        guard let handle = FileHandle(forReadingAtPath: file.path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var start = offsets[file.path] ?? 0
        if start > size { start = 0 }  // rewritten
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        // Only complete lines; a half-written last line is read next time.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        offsets[file.path] = start + UInt64(lastNewline - data.startIndex + 1)
        let usageKey = Data("\"usage\"".utf8), limitKey = Data("rate_limit".utf8)
        for line in data[..<lastNewline].split(separator: 0x0A) {
            let hasUsage = line.range(of: usageKey) != nil, hasLimit = line.range(of: limitKey) != nil
            guard hasUsage || hasLimit,
                  let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let stamp = entry["timestamp"] as? String, let date = Self.parseDate(stamp) else { continue }
            let message = entry["message"] as? [String: Any] ?? [:]
            if entry["isApiErrorMessage"] as? Bool == true {
                if let limit = Self.sessionLimit(entry, at: date) { limits[(entry["uuid"] as? String) ?? stamp] = limit }
                continue
            }
            guard let (id, weight) = Self.replyWeight(message) else { continue }
            // A reply can be written in several lines as it streams; keep the largest.
            if let old = replies[id], old.weight >= weight { continue }
            replies[id] = UsageReply(date: date, weight: weight)
        }
    }

    /// When the session limits seen in the last few days hit (LimitKeeper keeps them longer).
    var limitHits: [UsageLimit] { Array(limits.values) }

    /// A transcript's API-error entry as a session limit, or nil. Session limits only; a weekly limit says nothing
    /// about the 5-hour window.
    static func sessionLimit(_ entry: [String: Any], at date: Date) -> UsageLimit? {
        guard entry["error"] as? String == "rate_limit" else { return nil }
        let message = entry["message"] as? [String: Any] ?? [:]
        let parts = message["content"] as? [[String: Any]] ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
        guard text.range(of: "session limit", options: .caseInsensitive) != nil,
              let reset = ResetTime.parse(text, after: date) else { return nil }
        return UsageLimit(hitAt: date, resetsAt: reset)
    }

    /// A reply's message id and weight, or nil for anything that is not a model reply.
    static func replyWeight(_ message: [String: Any]) -> (String, Double)? {
        guard let id = message["id"] as? String, let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String, model != "<synthetic>" else { return nil }
        func n(_ key: String) -> Double { (usage[key] as? NSNumber)?.doubleValue ?? 0 }
        return (id, UsageEstimate.weight(model: model, input: n("input_tokens"), output: n("output_tokens"),
                                         cacheWrite: n("cache_creation_input_tokens"), cacheRead: n("cache_read_input_tokens")))
    }

    // ---- habits (Habits.swift): whole hours, the recent burn, and a time-sliced catch-up of older hours ----

    /// Weighted tokens per UTC hour for the whole hours this scan covers: from the first full hour after the 3-day
    /// cutoff through the current hour. The partial edge hour is left out, so it is never overwritten with a part.
    func hourTotals(now: Date) -> (fromHour: Int, throughHour: Int, totals: [Int: Double]) {
        let fromHour = Int(ceil((now.timeIntervalSince1970 - Self.history) / 3600))
        let throughHour = Int(floor(now.timeIntervalSince1970 / 3600))
        var totals: [Int: Double] = [:]
        for r in replies.values {
            let h = Int(floor(r.date.timeIntervalSince1970 / 3600))
            if h >= fromHour, h <= throughHour { totals[h, default: 0] += r.weight }
        }
        return (fromHour, throughHour, totals)
    }

    func weight(since: Date) -> Double {
        replies.values.reduce(0) { $1.date >= since ? $0 + $1.weight : $0 }
    }

    private var catchUpJob: (fromHour: Int, toHour: Int, files: [URL], seen: [String: (Int, Double)])?

    /// Reads replies from `fromHour` up to `toHour` from older transcripts, a few files per call (about `budget`
    /// seconds), in 1 MB chunks so a large transcript is never loaded whole. Returns the hourly totals when done,
    /// nil while there is more to read. A reply copied into several files counts once (its message id).
    func catchUp(fromHour: Int, toHour: Int, budget: TimeInterval) -> [Int: Double]? {
        guard fromHour <= toHour else { return [:] }
        if catchUpJob == nil || catchUpJob!.fromHour != fromHour || catchUpJob!.toHour != toHour {
            let since = Date(timeIntervalSince1970: Double(fromHour) * 3600)
            let fm = FileManager.default
            var files: [URL] = []
            for dir in (try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil)) ?? [] {
                for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                where file.pathExtension == "jsonl" {
                    if let m = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                       m >= since { files.append(file) }
                }
            }
            catchUpJob = (fromHour, toHour, files, [:])
        }
        let deadline = Date().addingTimeInterval(budget)
        while var job = catchUpJob, let file = job.files.first {
            job.files.removeFirst()
            Self.eachLine(of: file) { line in
                guard line.range(of: Data("\"usage\"".utf8)) != nil,
                      let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      entry["type"] as? String == "assistant", entry["isApiErrorMessage"] as? Bool != true,
                      let stamp = entry["timestamp"] as? String, let date = Self.parseDate(stamp),
                      let (id, w) = Self.replyWeight(entry["message"] as? [String: Any] ?? [:]) else { return }
                let h = Int(floor(date.timeIntervalSince1970 / 3600))
                guard h >= job.fromHour, h <= job.toHour else { return }
                if let old = job.seen[id], old.1 >= w { return }
                job.seen[id] = (h, w)
            }
            catchUpJob = job
            if Date() > deadline { break }
        }
        guard let job = catchUpJob, job.files.isEmpty else { return nil }
        catchUpJob = nil
        var totals: [Int: Double] = [:]
        for (h, w) in job.seen.values { totals[h, default: 0] += w }
        return totals
    }

    /// Calls `body` with each complete line of a file, reading 1 MB at a time.
    static func eachLine(of file: URL, _ body: (Data.SubSequence) -> Void) {
        guard let handle = FileHandle(forReadingAtPath: file.path) else { return }
        defer { try? handle.close() }
        var carry = Data()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            carry.append(chunk)
            guard let last = carry.lastIndex(of: 0x0A) else { continue }
            for line in carry[..<last].split(separator: 0x0A) { body(line) }
            carry = Data(carry[(last + 1)...])
        }
        if !carry.isEmpty { body(carry[...]) }
    }

    static func parseDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}

/// Opt-in exact usage: asks Anthropic's usage service with Claude Code's own sign-in, read
/// from the keychain (macOS asks once). The token is used for this one request only; it is
/// never logged, stored or sent anywhere else.
enum ExactUsage {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"

    enum Failure: Error, Equatable {
        case noSignIn, keychainDenied, expired, refused(Int), unreadable, offline
        var message: String {
            switch self {
            case .noSignIn: return "No Claude Code sign-in found. Run claude in Terminal and sign in."
            case .keychainDenied: return "Buddy couldn't read Claude Code's sign-in from the keychain."
            case .expired: return "Claude Code's sign-in has expired. Run claude in Terminal once to refresh it."
            case .refused(let code): return "Anthropic refused the request (\(code)). Run claude in Terminal once to refresh the sign-in."
            case .unreadable: return "Anthropic's answer was not in the expected shape."
            case .offline: return "Could not reach Anthropic."
            }
        }
        var signInHelps: Bool {
            switch self {
            case .noSignIn, .expired, .refused: return true
            case .keychainDenied, .unreadable, .offline: return false
            }
        }
    }

    /// Opens Terminal running `claude auth login`, which opens the sign-in page in your default
    /// browser and saves the sign-in to the keychain, where Buddy then finds it. Buddy never
    /// sees your password; it only reads the token Claude Code saved.
    /// With `switching`, signs the current account out first, so the browser asks which
    /// account to use instead of reusing the one already signed in.
    @MainActor
    static func openSignIn(switching: Bool = false) {
        let logout = switching ? "claude auth logout && echo && " : ""
        let script = """
        #!/bin/zsh -l
        # Opened by Buddy: signs Claude Code in so Buddy can show exact usage.
        clear
        if command -v claude >/dev/null 2>&1; then
          echo "Signing Claude Code in. Your browser opens to finish; come back here when it says you're done."
          echo
          \(logout)claude auth login && echo && echo "Signed in. Buddy picks it up within a few seconds; you can close this window."
        else
          echo "Claude Code isn't installed here (no claude command on your PATH)."
          echo "Install it from https://claude.com/claude-code, then try Sign In again from Buddy's Settings."
        fi
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Buddy Sign In.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            Log.note("could not write the sign-in script: \(error.localizedDescription)")
            return
        }
        Log.note("opening Terminal for claude auth login")
        NSWorkspace.shared.open(url)
    }

    static func fetch() async -> Result<UsageReading, Failure> {
        let token: (value: String, expired: Bool)
        switch signInToken() {
        case .success(let t): token = t
        case .failure(let f): return .failure(f)
        }
        guard !token.expired else { return .failure(.expired) }
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return .failure(.offline) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { return .failure(.refused(code)) }
        guard let reading = parse(data) else { return .failure(.unreadable) }
        return .success(reading)
    }

    /// `{"five_hour": {"utilization": 23, "resets_at": "..."}, "seven_day": {...}, ...}`
    static func parse(_ data: Data) -> UsageReading? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func window(_ key: String) -> UsageReading.Window? {
            guard let w = json[key] as? [String: Any], let pct = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return .init(percent: pct, resetsAt: (w["resets_at"] as? String).flatMap(UsageScanner.parseDate))
        }
        let session = window("five_hour"), week = window("seven_day")
        guard session != nil || week != nil else { return nil }
        var reading = UsageReading(session: session, week: week, exact: true)
        reading.opusWeek = window("seven_day_opus")
        return reading
    }

    /// Reads the item through /usr/bin/security, the tool Claude Code itself stores it with.
    /// Each renewal rewrites the item and resets its access list to that tool alone, so a
    /// direct keychain read asked for your password again every few hours (2026-10-23); the
    /// tool is always on the list. Not found (or no Claude sign-in in it) is `.noSignIn`; any
    /// other failure is `.keychainDenied`. The token stays in memory for this one request.
    private static func signInToken() -> Result<(value: String, expired: Bool), Failure> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(.keychainDenied) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // 44 is errSecItemNotFound's exit code from the security tool.
        guard p.terminationStatus != 44 else { return .failure(.noSignIn) }
        guard p.terminationStatus == 0 else {
            Log.note("keychain read of Claude Code's sign-in failed: \(p.terminationStatus)")
            return .failure(.keychainDenied)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let value = oauth["accessToken"] as? String, !value.isEmpty else { return .failure(.noSignIn) }
        let expiresMs = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? .infinity
        return .success((value, Date().timeIntervalSince1970 * 1000 >= expiresMs))
    }
}

/// The account Claude Code is signed in with, from `claude auth status`. Shown in Settings so
/// a wrong account is easy to spot; Buddy keeps no account of its own.
struct ClaudeAccount: Equatable {
    var email: String
    var orgName: String?

    /// `{"loggedIn": true, "email": "...", "orgName": "...", ...}`; nil when signed out.
    static func parse(_ data: Data) -> ClaudeAccount? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["loggedIn"] as? Bool == true, let email = json["email"] as? String, !email.isEmpty else { return nil }
        let org = (json["orgName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ClaudeAccount(email: email, orgName: org)
    }

    /// Asks the claude command (through a login shell, so its usual PATH applies). Nil when
    /// signed out or when Claude Code is not installed.
    static func current() async -> ClaudeAccount? {
        guard let out = await run("claude auth status --json") else { return nil }
        return parse(out)
    }

    /// Signs Claude Code out on this Mac (for Terminal too). True when it worked.
    static func signOut() async -> Bool {
        let ok = await run("claude auth logout") != nil
        Log.note(ok ? "signed Claude Code out" : "claude auth logout failed")
        return ok
    }

    /// Claude Code's access token lasts about eight hours and only the claude command renews
    /// it, which the Claude app's chats don't do. `claude doctor` (a one-second health check
    /// that spends no usage) renews it as a side effect. Run from an empty folder so it reads
    /// no project's settings. True when the command ran; the caller checks the result.
    static func renewSignIn() async -> Bool {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-renew", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let quoted = "'" + folder.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return await run("cd \(quoted) && claude doctor") != nil
    }

    /// Runs one fixed command line; the output when it exits 0 within 20 seconds.
    private static func run(_ command: String) async -> Data? {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", command]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { done.resume(returning: nil); return }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                done.resume(returning: p.terminationStatus == 0 ? data : nil)
            }
        }
    }
}
