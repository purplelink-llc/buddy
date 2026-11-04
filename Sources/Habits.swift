import Foundation

// Usage habits for the weekly pace (docs/designs/weekly-usage-pace.md, v3.1): how much Claude Code use this Mac
// usually sees in each hour of the week, learned from its own transcripts and kept in a small local file.

/// The stored hours: weighted tokens per UTC hour (hours since 1970) and the UTC offset that hour had, so a
/// daylight-saving change or a trip never merges or loses an hour.
struct HabitData: Codable, Equatable {
    var version = 1
    /// The newest moment the hours are complete up to.
    var scannedThrough: Double?
    /// Set while a catch-up (first run, or Buddy was off for days) still has older hours to read.
    var catchUpFrom: Double?
    var hours: [String: [Double]] = [:]   // "<UTC hour>": [weighted tokens, UTC offset in seconds]
    /// Finished weeks, newest last (at most 8): [reset, final percent, local tokens, error at day 2, 4, 6 or -1].
    var weeks: [[Double]] = []
    /// The latest exact week reading: [reset, percent, read at].
    var lastWeek: [Double]?
    /// The current week's first projection at or after day 2, 4 and 6 ("2", "4", "6"), and the reset they belong to.
    var projections: [String: Double] = [:]
    var projectionsReset: Double?

    static let keep: TimeInterval = 28 * 86400
    static let leads = [2, 4, 6]

    /// Percent of the weekly limit per weighted token on this Mac, the median over finished weeks that did not hit
    /// the limit. It assumes other devices keep a similar share of the use.
    var learnedK: Double? {
        HabitProfile.median(weeks.compactMap { w in w.count >= 3 && w[1] < 100 && w[2] > 0 ? w[1] / w[2] : nil })
    }

    /// How far forecasts made this far into a week have been off, in points: the median over graded weeks at the
    /// matching lead time, ±20 with no graded week, moving linearly to that median by three.
    func band(elapsedDays: Double) -> Double {
        let lead = elapsedDays < 4 ? 0 : elapsedDays < 6 ? 1 : 2
        let errors = weeks.compactMap { $0.count >= 6 && $0[3 + lead] >= 0 ? $0[3 + lead] : nil }
        guard let median = HabitProfile.median(errors) else { return 20 }
        let n = Double(min(errors.count, 3))
        return (20 * (3 - n) + median * n) / 3
    }

    /// The day-4 error over graded weeks, for Settings: (median points, weeks).
    var midWeekAccuracy: (points: Double, weeks: Int)? {
        let errors = weeks.compactMap { $0.count >= 6 && $0[4] >= 0 ? $0[4] : nil }
        return HabitProfile.median(errors).map { ($0, errors.count) }
    }

    /// Days of hours learned: from the oldest stored hour to the last scan.
    var learnedDays: Double {
        guard let oldest = hours.keys.compactMap(Int.init).min(), let through = scannedThrough else { return 0 }
        return max(0, (through - Double(oldest) * 3600) / 86400)
    }

    /// Sets every hour from `fromHour` through `throughHour` to its total (0 when absent), with the offset each had.
    mutating func set(_ totals: [Int: Double], fromHour: Int, throughHour: Int, offset: (Int) -> Int) {
        guard fromHour <= throughHour else { return }
        for h in fromHour...throughHour { hours[String(h)] = [totals[h] ?? 0, Double(offset(h))] }
    }

    mutating func prune(now: Date) {
        let oldest = Int((now.timeIntervalSince1970 - Self.keep) / 3600)
        hours = hours.filter { (Int($0.key) ?? 0) >= oldest }
    }

    func tokens(fromHour: Int, toHour: Int) -> Double {
        guard fromHour < toHour else { return 0 }
        return (fromHour..<toHour).reduce(0) { $0 + (hours[String($1)]?.first ?? 0) }
    }
}

extension HabitData {
    /// Every field optional on the way in, so a file from an earlier version loads instead of starting over.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        scannedThrough = try c.decodeIfPresent(Double.self, forKey: .scannedThrough)
        catchUpFrom = try c.decodeIfPresent(Double.self, forKey: .catchUpFrom)
        hours = try c.decodeIfPresent([String: [Double]].self, forKey: .hours) ?? [:]
        weeks = try c.decodeIfPresent([[Double]].self, forKey: .weeks) ?? []
        lastWeek = try c.decodeIfPresent([Double].self, forKey: .lastWeek)
        projections = try c.decodeIfPresent([String: Double].self, forKey: .projections) ?? [:]
        projectionsReset = try c.decodeIfPresent(Double.self, forKey: .projectionsReset)
    }

    /// After an exact week reading: end the stored week if this reading belongs to a later one (recording it only when
    /// its data is complete), remember this reading, and keep the first projection at days 2, 4 and 6. Idempotent.
    mutating func observe(percent: Double, resetsAt reset: Date, now: Date, projected: Double?) {
        let r = reset.timeIntervalSince1970
        if let last = lastWeek, last.count == 3, r > last[0] + 3600 {
            let oldReset = last[0]
            // Whole hours of the week, from the reset hour rounded to the nearest hour (resets jitter by minutes).
            let endHour = Int((oldReset / 3600).rounded())
            let local = tokens(fromHour: endHour - 7 * 24, toHour: endHour)
            if last[2] >= oldReset - 6 * 3600, catchUpFrom == nil, (scannedThrough ?? 0) >= oldReset, local > 0 {
                let final = min(last[1], 100)
                let errors = Self.leads.map { lead -> Double in
                    guard let pr = projectionsReset, abs(pr - oldReset) <= 3600, let p = projections[String(lead)] else { return -1 }
                    return abs(min(p, 100) - final)
                }
                weeks = Array((weeks + [[oldReset, last[1], local] + errors]).suffix(8))
            }
            projections = [:]
            projectionsReset = nil
        }
        if lastWeek == nil || r > (lastWeek?[0] ?? 0) - 3600 { lastWeek = [r, percent, now.timeIntervalSince1970] }
        let elapsedDays = (now.timeIntervalSince1970 - (r - UsageReading.weekLength)) / 86400
        if let projected {
            // The same week within an hour of reset jitter keeps its projections.
            if projectionsReset.map({ abs($0 - r) > 3600 }) ?? true { projections = [:]; projectionsReset = r }
            for lead in Self.leads where elapsedDays >= Double(lead) && projections[String(lead)] == nil {
                projections[String(lead)] = projected
            }
        }
    }

    /// Seven 24-hour slots from the window's start: this Mac's use in each (whole hours stored so far).
    func slots(windowStart: Date) -> [Double] {
        (0..<7).map { i in
            let a = windowStart.timeIntervalSince1970 + Double(i) * 86400
            return tokens(fromHour: Int(ceil(a / 3600)), toHour: Int(ceil((a + 86400) / 3600)))
        }
    }
}

/// The usual week: for each of the 168 local hours of the week, the median of that hour across the stored weeks,
/// plus a small floor so an hour never used still counts a little.
struct HabitProfile: Equatable {
    var perHour: [Double]          // index: weekday (0 = Sunday) × 24 + hour, local wall clock
    var typicalWeek: Double        // sum of perHour

    static let readySpan: TimeInterval = 21 * 86400

    /// nil until the stored hours span 21 days.
    init?(_ data: HabitData, now: Date) {
        let keys = data.hours.keys.compactMap(Int.init)
        guard let oldest = keys.min(), now.timeIntervalSince1970 - Double(oldest) * 3600 >= Self.readySpan else { return nil }
        var buckets = Array(repeating: [Double](), count: 168)
        var total = 0.0
        for (key, value) in data.hours {
            guard let h = Int(key), value.count == 2 else { continue }
            buckets[Self.index(hour: h, offset: Int(value[1]))].append(value[0])
            total += value[0]
        }
        let floor = 0.02 * total / Double(max(1, data.hours.count))
        perHour = buckets.map { (Self.median($0) ?? 0) + floor }
        typicalWeek = perHour.reduce(0, +)
    }

    init(perHour: [Double]) {
        self.perHour = perHour
        typicalWeek = perHour.reduce(0, +)
    }

    static func index(hour: Int, offset: Int) -> Int {
        let local = Double(hour) * 3600 + Double(offset)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.weekday, .hour], from: Date(timeIntervalSince1970: local))
        return ((parts.weekday ?? 1) - 1) * 24 + (parts.hour ?? 0)
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// Expected weighted tokens between two moments, hour by hour in the given time zone, partial hours pro rata.
    func expected(from start: Date, to end: Date, timeZone: TimeZone = .current) -> Double {
        guard end > start else { return 0 }
        var t = start.timeIntervalSince1970, sum = 0.0
        let stop = end.timeIntervalSince1970
        while t < stop {
            let hour = Int(floor(t / 3600))
            let next = min(Double(hour + 1) * 3600, stop)
            let offset = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: t))
            sum += perHour[Self.index(hour: hour, offset: offset)] * (next - t) / 3600
            t = next
        }
        return sum
    }

    /// The moment expected use from `start` reaches `amount`, or nil if not before `limit`.
    func reaches(_ amount: Double, from start: Date, before limit: Date, timeZone: TimeZone = .current) -> Date? {
        var t = start.timeIntervalSince1970, sum = 0.0
        let stop = limit.timeIntervalSince1970
        while t < stop {
            let hour = Int(floor(t / 3600))
            let next = min(Double(hour + 1) * 3600, stop)
            let rate = perHour[Self.index(hour: hour, offset: timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: t)))] / 3600
            if rate > 0, sum + rate * (next - t) >= amount { return Date(timeIntervalSince1970: t + (amount - sum) / rate) }
            sum += rate * (next - t)
            t = next
        }
        return nil
    }
}

/// What the weekly pace needs from the habits: the profile, and this Mac's use by hour for the current week.
struct HabitInputs: Equatable {
    var profile: HabitProfile
    var data: HabitData
    /// Weighted tokens in the last 2 hours (the recent-burn floor).
    var recent2h: Double
}

extension UsagePace {
    /// The weekly pace by your usual hours: percent + k × the use your habits expect before the reset, where k is the
    /// percent each weighted token cost this week. Never below the recent burn carried for up to 2 hours. nil (the
    /// caller then uses the time-based pace) under v2's gates, or when this Mac saw too little of the week's use.
    static func weekPace(percent: Double, resetsAt: Date?, now: Date, habits: HabitInputs,
                         timeZone: TimeZone = .current) -> UsagePace? {
        guard let reset = resetsAt, reset > now, percent >= 3, percent < 100 else { return nil }
        let start = reset.addingTimeInterval(-UsageReading.weekLength)
        let elapsed = now.timeIntervalSince(start)
        let learned = habits.data.learnedK
        guard elapsed >= (learned != nil ? 6 : 24) * 3600, elapsed <= UsageReading.weekLength else { return nil }
        let local = habits.data.tokens(fromHour: Int(ceil(start.timeIntervalSince1970 / 3600)),
                                       toHour: Int(floor(now.timeIntervalSince1970 / 3600)))
        let k: Double
        if let learned {
            // Blend this week's k into the learned one as this week's local use grows, so it never jumps.
            let w = min(1, local / (0.2 * habits.profile.typicalWeek))
            k = local > 0 ? w * (percent / local) + (1 - w) * learned : learned
        } else {
            guard local > 0.02 * habits.profile.typicalWeek, local > 0 else { return nil }
            k = percent / local
        }
        let ahead = habits.profile.expected(from: now, to: reset, timeZone: timeZone)
        let left = reset.timeIntervalSince(now)
        let burnPerSecond = k * habits.recent2h / 7200
        let projected = max(percent + k * ahead, percent + burnPerSecond * min(left, 7200) + k * habits.profile
            .expected(from: now.addingTimeInterval(min(left, 7200)), to: reset, timeZone: timeZone))
        let band = habits.data.band(elapsedDays: elapsed / 86400)
        guard projected.rounded() > 100 else { return UsagePace(projected: projected, runsOutAt: nil, basis: .habits, band: band) }
        let need = 100 - percent
        var out = habits.profile.reaches(need / k, from: now, before: reset, timeZone: timeZone)
        if burnPerSecond > 0 {
            let byBurn = now.addingTimeInterval(need / burnPerSecond)
            if byBurn < reset, byBurn < (out ?? reset) { out = byBurn }
        }
        let rounded = out.map { Date(timeIntervalSinceReferenceDate: ($0.timeIntervalSinceReferenceDate / 300).rounded() * 300) }
        return UsagePace(projected: projected, runsOutAt: rounded, basis: .habits, band: band)
    }
}

/// The habits file and its upkeep. Used only on the scanner's serial queue.
final class HabitKeeper: @unchecked Sendable {
    let url: URL
    private(set) var data: HabitData
    private var loaded = false
    /// Bumped by forget, so a result computed before it is never shown after it.
    private(set) var generation = 0

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Buddy/habits.json")) {
        self.url = url
        data = HabitData()
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        if let raw = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(HabitData.self, from: raw),
           decoded.version == 1 {
            data = decoded
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(data).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.note("could not save usage habits: \(error.localizedDescription)")
        }
    }

    func forget() {
        data = HabitData()
        loaded = true
        generation += 1
        try? FileManager.default.removeItem(at: url)
    }

    /// After a successful exact reading (on the scanner's queue): week ends, the learned share and grading.
    func observe(_ reading: UsageReading, now: Date) {
        load()
        guard let week = reading.week, let reset = week.resetsAt else { return }
        let profile = HabitProfile(data, now: now)
        let inputs = profile.map { HabitInputs(profile: $0, data: data, recent2h: 0) }
        let projected = inputs.flatMap { UsagePace.weekPace(percent: week.percent, resetsAt: reset, now: now, habits: $0) }
            ?? UsagePace.pace(percent: week.percent, resetsAt: reset, length: UsageReading.weekLength, now: now)
        let before = data
        data.observe(percent: week.percent, resetsAt: reset, now: now, projected: projected?.projected)
        if data != before { save() }
    }

    /// After a scan: rewrite the scan's whole hours, start or continue a catch-up for older hours, prune, save, and
    /// return what the pace needs (nil until the profile is ready).
    func update(scanner: UsageScanner, now: Date, budget: TimeInterval = 0.4) -> HabitInputs? {
        load()
        let tz = TimeZone.current
        let offset: (Int) -> Int = { tz.secondsFromGMT(for: Date(timeIntervalSince1970: Double($0) * 3600)) }
        let recent = scanner.hourTotals(now: now)
        data.set(recent.totals, fromHour: recent.fromHour, throughHour: recent.throughHour, offset: offset)
        let windowStart = Double(recent.fromHour) * 3600
        if data.catchUpFrom == nil, (data.scannedThrough ?? 0) < windowStart {
            data.catchUpFrom = max(data.scannedThrough ?? 0, now.timeIntervalSince1970 - HabitData.keep)
        }
        if let from = data.catchUpFrom {
            let fromHour = Int(ceil(from / 3600)), toHour = recent.fromHour - 1
            if let older = scanner.catchUp(fromHour: fromHour, toHour: toHour, budget: budget) {
                data.set(older, fromHour: fromHour, throughHour: toHour, offset: offset)
                data.catchUpFrom = nil
            }
        }
        data.scannedThrough = now.timeIntervalSince1970
        data.prune(now: now)
        save()
        guard data.catchUpFrom == nil, let profile = HabitProfile(data, now: now) else { return nil }
        return HabitInputs(profile: profile, data: data, recent2h: scanner.weight(since: now.addingTimeInterval(-7200)))
    }
}
