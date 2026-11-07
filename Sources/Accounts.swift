import Foundation

// Which Claude account is in use, and when session limits usually hit (docs/designs/account-and-limit-times.md).
// Everything here reads local files only. Buddy never signs in, out or between accounts.

/// The Claude app's signed-in account and Claude Code's, by the names given to them in ~/.claude-accounts
/// (the folders the account switcher saves to), else by email or a short id.
struct AccountTag: Equatable {
    /// The Claude app's account (its Code tab chats run on it).
    var app: String?
    /// Claude Code's own sign-in, which exact usage reads.
    var code: String?

    /// True when both are known and differ: exact usage then shows a different account than the app's chats use.
    var mismatch: Bool { app != nil && code != nil && app != code }

    /// `lastKnownAccountUuid` from the Claude app's config.json.
    static func appUuid(_ config: Data) -> String? {
        let json = (try? JSONSerialization.jsonObject(with: config)) as? [String: Any]
        return (json?["lastKnownAccountUuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Claude Code's account in ~/.claude.json: its uuid and email.
    static func codeAccount(_ claudeJSON: Data) -> (uuid: String, email: String?)? {
        let json = (try? JSONSerialization.jsonObject(with: claudeJSON)) as? [String: Any]
        guard let account = json?["oauthAccount"] as? [String: Any],
              let uuid = account["accountUuid"] as? String, !uuid.isEmpty else { return nil }
        return (uuid, account["emailAddress"] as? String)
    }

    /// uuid → name, from each ~/.claude-accounts/<name>/account file.
    static func savedNames(in root: URL) -> [String: String] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var names: [String: String] = [:]
        for folder in folders {
            guard let raw = try? String(contentsOf: folder.appendingPathComponent("account"), encoding: .utf8) else { continue }
            let uuid = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !uuid.isEmpty { names[uuid] = folder.lastPathComponent }
        }
        return names
    }

    static func name(_ uuid: String, email: String?, names: [String: String]) -> String {
        if let n = names[uuid] { return n }
        if let e = email, let at = e.firstIndex(of: "@") { return String(e[..<at]) }
        return String(uuid.prefix(8))
    }

    /// Reads the files under `home`; nil when neither account is known.
    static func current(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AccountTag? {
        let names = savedNames(in: home.appendingPathComponent(".claude-accounts", isDirectory: true))
        let config = home.appendingPathComponent("Library/Application Support/Claude/config.json")
        let app = (try? Data(contentsOf: config)).flatMap(appUuid).map { name($0, email: nil, names: names) }
        let code = (try? Data(contentsOf: home.appendingPathComponent(".claude.json"))).flatMap(codeAccount)
            .map { name($0.uuid, email: $0.email, names: names) }
        guard app != nil || code != nil else { return nil }
        return AccountTag(app: app, code: code)
    }
}

/// Session-limit hits kept for four weeks, and the times of day they usually come.
struct LimitLog: Codable, Equatable {
    struct Hit: Codable, Equatable {
        var at: Double
        /// The Claude app's account when Buddy saw the hit live; nil for hits found later in old transcripts.
        var account: String?
        /// When that limit reset; later hits before then are retries running into the same limit.
        var resets: Double?
    }
    var version = 1
    var hits: [Hit] = []
    /// Set once the four weeks before Buddy started keeping the log have been read from transcripts.
    var backfilled = false

    static let keep: TimeInterval = 28 * 86400
    /// Hits this close together are the same limit (several chats stop at once).
    static let sameHit: TimeInterval = 10 * 60

    /// Adds limits not already kept, tagging the ones from the last 15 minutes with `account`, and drops old ones.
    /// A hit before a kept hit's reset is the same limit (a retry, or another chat), so only its first hit counts.
    mutating func record(_ limits: [UsageLimit], account: String?, now: Date) {
        for l in limits.sorted(by: { $0.hitAt < $1.hitAt }) {
            let t = l.hitAt.timeIntervalSince1970
            guard t > now.timeIntervalSince1970 - Self.keep,
                  !hits.contains(where: { t > $0.at - Self.sameHit && t < max($0.at + Self.sameHit, $0.resets ?? 0) })
            else { continue }
            hits.append(Hit(at: t, account: now.timeIntervalSince(l.hitAt) < 15 * 60 ? account : nil,
                            resets: l.resetsAt.timeIntervalSince1970))
        }
        hits = hits.filter { $0.at > now.timeIntervalSince1970 - Self.keep }.sorted { $0.at < $1.at }
    }

    /// Hits that count for `account`: its own and the untagged ones.
    func dates(for account: String?) -> [Date] {
        hits.filter { $0.account == nil || account == nil || $0.account == account }
            .map { Date(timeIntervalSince1970: $0.at) }
    }
}

enum LimitTimes {
    /// Minutes between two times of day, the short way round midnight.
    static func gap(_ a: Int, _ b: Int) -> Int {
        let d = abs(a - b) % 1440
        return min(d, 1440 - d)
    }

    /// Times of day (minutes after local midnight, to 5 minutes) when the session limit usually hits: each one has
    /// hits within an hour of it on at least three different days of the last four weeks, and on at least a quarter
    /// of the days that had any limit (someone who runs out at all hours has no usual time). Earliest first.
    static func usual(_ hits: [Date], now: Date, calendar: Calendar = .current) -> [Int] {
        var left: [(day: Date, minute: Int)] = hits
            .filter { $0 <= now && now.timeIntervalSince($0) < LimitLog.keep }
            .map { d in
                let c = calendar.dateComponents([.hour, .minute], from: d)
                return (calendar.startOfDay(for: d), (c.hour ?? 0) * 60 + (c.minute ?? 0))
            }
        let minDays = max(3, (Set(left.map(\.day)).count + 3) / 4)
        var found: [Int] = []
        while !left.isEmpty {
            // The hit with the most different days near it; ties go to more hits, then the earlier time.
            let best = left.map { p -> (minute: Int, days: Int, count: Int) in
                let near = left.filter { gap($0.minute, p.minute) <= 60 }
                return (p.minute, Set(near.map(\.day)).count, near.count)
            }.max { a, b in (a.days, a.count, -a.minute) < (b.days, b.count, -b.minute) }!
            guard best.days >= minDays else { break }
            let near = left.filter { gap($0.minute, best.minute) <= 60 }
            // Their average, measured from the best hit so a cluster across midnight averages correctly.
            let offsets = near.map { p -> Int in
                var d = p.minute - best.minute
                if d > 720 { d -= 1440 } else if d < -720 { d += 1440 }
                return d
            }
            let mean = Double(offsets.reduce(0, +)) / Double(offsets.count)
            let center = ((best.minute + Int((mean / 5).rounded()) * 5) % 1440 + 1440) % 1440
            found.append(center / 5 * 5)
            left.removeAll { gap($0.minute, best.minute) <= 60 }
        }
        return found.sorted()
    }

    /// The next usual time within `lead` of now, as a date, or nil.
    static func upcoming(_ usual: [Int], now: Date, lead: TimeInterval = 3600, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        return usual.flatMap { m -> [Date] in
            [0, 1].compactMap { day in
                calendar.date(byAdding: .day, value: day, to: today)
                    .flatMap { calendar.date(byAdding: .minute, value: m, to: $0) }
            }
        }
        .filter { $0 > now && $0.timeIntervalSince(now) <= lead }
        .min()
    }

    /// "3 PM" or "3:30 PM".
    static func label(_ minute: Int, calendar: Calendar = .current) -> String {
        let date = calendar.date(byAdding: .minute, value: minute, to: calendar.startOfDay(for: Date()))!
        return minute % 60 == 0 ? date.formatted(.dateTime.hour()) : date.formatted(date: .omitted, time: .shortened)
    }
}

/// The limit log file and its upkeep. Used only on the scanner's serial queue.
final class LimitKeeper: @unchecked Sendable {
    let url: URL
    private(set) var log = LimitLog()
    private var loaded = false

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Buddy/limits.json")) {
        self.url = url
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let raw = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(LimitLog.self, from: raw),
           decoded.version == 1 {
            log = decoded
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(log).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.note("could not save limit times: \(error.localizedDescription)")
        }
    }

    /// After a scan: keep the scanner's recent hits (and, the first time, four weeks of older ones), and return the
    /// usual times for `account`.
    func update(scanner: UsageScanner, account: String?, now: Date) -> [Int] {
        load()
        let before = log
        if !log.backfilled {
            log.record(Self.olderHits(in: scanner.projectsRoot, now: now), account: nil, now: now)
            log.backfilled = true
        }
        log.record(scanner.limitHits, account: account, now: now)
        if log != before { save() }
        return LimitTimes.usual(log.dates(for: account), now: now)
    }

    /// Session-limit hits in transcripts changed in the last four weeks. Reads only lines that mention rate_limit.
    static func olderHits(in root: URL, now: Date) -> [UsageLimit] {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-LimitLog.keep)
        let key = Data("rate_limit".utf8)
        var found: [UsageLimit] = []
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modified >= cutoff else { continue }
                UsageScanner.eachLine(of: file) { line in
                    guard line.range(of: key) != nil,
                          let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                          entry["isApiErrorMessage"] as? Bool == true,
                          let stamp = entry["timestamp"] as? String, let date = UsageScanner.parseDate(stamp),
                          let limit = UsageScanner.sessionLimit(entry, at: date) else { return }
                    found.append(limit)
                }
            }
        }
        return found
    }
}
