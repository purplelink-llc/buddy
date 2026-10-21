import Foundation
import Security

/// Plan usage shown at the top of Buddy's list: the 5-hour session window and, when exact,
/// the weekly window.
struct UsageReading: Equatable {
    struct Window: Equatable {
        var percent: Double
        var resetsAt: Date?
    }
    var session: Window?
    var week: Window?
    /// True when the numbers come from Anthropic; false for Buddy's local estimate.
    var exact: Bool
    /// Why exact usage is unavailable right now, if it was asked for.
    var note: String?
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
                guard entry["error"] as? String == "rate_limit" else { continue }
                let parts = message["content"] as? [[String: Any]] ?? []
                let text = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
                // Session limits only; a weekly limit says nothing about the 5-hour window.
                guard text.range(of: "session limit", options: .caseInsensitive) != nil,
                      let reset = ResetTime.parse(text, after: date) else { continue }
                limits[(entry["uuid"] as? String) ?? stamp] = UsageLimit(hitAt: date, resetsAt: reset)
                continue
            }
            guard let id = message["id"] as? String, let usage = message["usage"] as? [String: Any],
                  let model = message["model"] as? String, model != "<synthetic>" else { continue }
            func n(_ key: String) -> Double { (usage[key] as? NSNumber)?.doubleValue ?? 0 }
            let weight = UsageEstimate.weight(model: model, input: n("input_tokens"), output: n("output_tokens"),
                                              cacheWrite: n("cache_creation_input_tokens"), cacheRead: n("cache_read_input_tokens"))
            // A reply can be written in several lines as it streams; keep the largest.
            if let old = replies[id], old.weight >= weight { continue }
            replies[id] = UsageReply(date: date, weight: weight)
        }
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
        case noSignIn, expired, refused(Int), unreadable, offline
        var message: String {
            switch self {
            case .noSignIn: return "No Claude Code sign-in found. Run claude in Terminal and sign in."
            case .expired: return "Claude Code's sign-in has expired. Run claude in Terminal once to refresh it."
            case .refused(let code): return "Anthropic refused the request (\(code)). Run claude in Terminal once to refresh the sign-in."
            case .unreadable: return "Anthropic's answer was not in the expected shape."
            case .offline: return "Could not reach Anthropic."
            }
        }
    }

    static func fetch() async -> Result<UsageReading, Failure> {
        guard let token = signInToken() else { return .failure(.noSignIn) }
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
        return UsageReading(session: session, week: week, exact: true)
    }

    private static func signInToken() -> (value: String, expired: Bool)? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let value = oauth["accessToken"] as? String, !value.isEmpty else { return nil }
        let expiresMs = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? .infinity
        return (value, Date().timeIntervalSince1970 * 1000 >= expiresMs)
    }
}
