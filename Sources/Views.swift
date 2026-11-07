import SwiftUI

extension Mood {
    var color: Color {
        switch self {
        case .idle: return .gray
        case .paused: return .purple
        case .done: return .green
        case .working: return Color(red: 0.35, green: 0.62, blue: 1)
        case .attention: return .orange
        }
    }
}

/// The little guy: a purple Lab/Chow pup's face with upright triangle ears. Glances around
/// while Claude works, hops when it needs you, smiles with his tongue out when it is done,
/// blinks when idle.
struct Guy: View {
    let mood: Mood
    let size: CGFloat
    /// Hop eagerly; after the first seconds a waiting guy hops only now and then.
    var urgent = false

    @State private var blink = false
    @State private var look: CGFloat = 0
    @State private var hop = false

    private let fur = Color(red: 0.64, green: 0.50, blue: 0.90)
    private let furShade = Color(red: 0.50, green: 0.36, blue: 0.80)
    private let light = Color(red: 0.88, green: 0.81, blue: 0.98)
    private let ink = Color(red: 0.13, green: 0.09, blue: 0.20)

    var body: some View {
        let s = size
        ZStack {
            ear.position(x: s * 0.25, y: s * 0.25)
            ear.scaleEffect(x: -1).position(x: s * 0.75, y: s * 0.25)
            RoundedRectangle(cornerRadius: s * 0.34, style: .continuous)
                .fill(LinearGradient(colors: [fur, furShade], startPoint: .top, endPoint: .bottom))
                .frame(width: s * 0.94, height: s * 0.72)
                .position(x: s * 0.5, y: s * 0.62)
            if mood == .done {  // over the head, under the muzzle, so it hangs out from under it
                Capsule().fill(Color(red: 0.98, green: 0.47, blue: 0.58))
                    .frame(width: s * 0.13, height: s * 0.16)
                    .position(x: s * 0.5, y: s * 0.91)
            }
            Ellipse().fill(light)
                .frame(width: s * 0.46, height: s * 0.27)
                .position(x: s * 0.5, y: s * 0.78)
            Ellipse().fill(ink)
                .frame(width: s * 0.17, height: s * 0.11)
                .position(x: s * 0.5, y: s * 0.70)
            eye.position(x: s * 0.31 + look * s * 0.025, y: s * 0.54)
            eye.position(x: s * 0.69 + look * s * 0.025, y: s * 0.54)
        }
        .frame(width: s, height: s)
        .offset(y: hop ? -s * 0.16 : 0)
        .task(id: "\(mood.rawValue)-\(urgent)") { await animate() }
    }

    /// A short triangle ear pointing straight up, with a lighter inside.
    private var ear: some View {
        ZStack {
            Ear().fill(fur)
            Ear().fill(light.opacity(0.85))
                .frame(width: size * 0.16, height: size * 0.12)
                .offset(x: size * 0.01, y: size * 0.035)
        }
        .frame(width: size * 0.34, height: size * 0.25)
    }

    @ViewBuilder private var eye: some View {
        if mood == .done {
            HappyEye().stroke(ink, style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round))
                .frame(width: size * 0.15, height: size * 0.08)
        } else {
            let d = size * (mood == .attention ? 0.16 : 0.13)
            Circle().fill(ink)
                .frame(width: d, height: d)
                .overlay(Circle().fill(.white).frame(width: d * 0.36, height: d * 0.36)
                    .offset(x: -d * 0.18, y: -d * 0.18))
                .scaleEffect(y: blink ? 0.12 : 1)
        }
    }

    private func animate() async {
        look = 0
        hop = false
        if mood == .done { await jump() }
        while !Task.isCancelled {
            switch mood {
            case .working:
                withAnimation(.easeInOut(duration: 0.35)) { look = [-1, 0, 1].randomElement()! }
                await pause(.random(in: 1.0...2.2))
                if Bool.random() { await doBlink() }
            case .attention:
                await jump()
                await pause(urgent ? 1.4 : 6)
            case .idle, .done, .paused:
                await pause(.random(in: 3...6))
                await doBlink()
            }
        }
    }

    private func jump() async {
        withAnimation(.easeOut(duration: 0.16)) { hop = true }
        await pause(0.16)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.45)) { hop = false }
        await pause(0.3)
    }

    private func doBlink() async {
        withAnimation(.easeIn(duration: 0.07)) { blink = true }
        await pause(0.1)
        withAnimation(.easeOut(duration: 0.1)) { blink = false }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// An upright triangle with a softly rounded tip and base corners.
struct Ear: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX - r.width * 0.08, y: r.minY + r.height * 0.08))
        p.addQuadCurve(to: CGPoint(x: r.midX + r.width * 0.08, y: r.minY + r.height * 0.08),
                       control: CGPoint(x: r.midX, y: r.minY - r.height * 0.04))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// A "^" shaped eye.
struct HappyEye: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - r.height * 0.6))
        return p
    }
}

/// Flat top (it hangs from the screen edge), rounded bottom corners.
struct NotchShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in r: CGRect) -> Path {
        Path(roundedRect: r, cornerRadii: .init(topLeading: 0, bottomLeading: radius,
                                                bottomTrailing: radius, topTrailing: 0),
             style: .continuous)
    }
}

struct PillView: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState

    var body: some View {
        VStack(spacing: 0) {
            if ui.shown {
                pill.transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            }
            Spacer(minLength: 0)
        }
        // The window is sized to the pill; draw from its top centre.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: ui.shown)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: ui.expanded)
        .environment(\.colorScheme, .dark)
    }

    private var pill: some View {
        let size = ui.size
        return VStack(spacing: 0) {
            header.frame(height: ui.geometry.barHeight)
            if ui.expanded { rows }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(.black)
        .clipShape(NotchShape(radius: ui.expanded ? 18 : 10))
        .contentShape(Rectangle())
        .contextMenu { menu }
    }

    private var header: some View {
        // Each ear is the space beside the notch (46 or 84 pt); nothing reaches under the camera.
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Guy(mood: store.overallMood, size: ui.geometry.barHeight * 0.66, urgent: store.peek != nil)
                    .padding(.leading, 12)
                if let shown = store.shownUsage {
                    usageBadge(shown.window, week: shown.isWeek, exact: store.usage?.exact == true)
                }
                Spacer(minLength: 0)
            }
            .frame(width: ui.earWidth)
            Spacer(minLength: 0)
            // Both at their own width, so the badge never squeezes the countdown into "1h 5…".
            HStack(spacing: 2) {
                if let reset = ui.resetCountdown {
                    resetTimer(reset.date, limit: reset.limit).fixedSize().layoutPriority(1).padding(.leading, 7)
                }
                Spacer(minLength: 0)
                badge.fixedSize()
            }
            .padding(.trailing, 7)
            .frame(width: ui.earWidth)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Option-click flips the notch between the session and the week; a plain click opens the top chat.
            if NSEvent.modifierFlags.contains(.option), store.exactUsageOn {
                store.notchWindow = store.notchWindow == .week ? .session : .week
            } else {
                store.openTop()
            }
        }
        .help(store.ordered.isEmpty ? "" : "Click to go to the session that needs you most")
    }

    @ViewBuilder private var badge: some View {
        if store.attentionCount > 0 {
            Text("\(store.attentionCount)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .frame(minWidth: 16, minHeight: 16)
                .background(Circle().fill(.orange))
        } else if !store.pausedSessions.isEmpty {
            // The countdown itself sits beside the notch when there is room for it there.
            if ui.resetCountdown?.limit == true {
                Image(systemName: "hourglass").font(.system(size: 11, weight: .bold)).foregroundStyle(.purple)
            } else {
                countdown
            }
        } else if !store.disconnectedSessions.isEmpty {
            Image(systemName: "wifi.slash").font(.system(size: 11, weight: .bold)).foregroundStyle(.purple)
                .help("Chats stopped by a dropped connection; Buddy retries them when you're back online")
        } else if store.unseenDoneCount > 0 {
            HStack(spacing: 3) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                if store.unseenDoneCount > 1 {
                    Text("\(store.unseenDoneCount)").font(.system(size: 11, weight: .semibold, design: .rounded))
                }
            }
            .foregroundStyle(.green)
        } else if store.workingCount > 0 {
            HStack(spacing: 4) {
                Circle().fill(Mood.working.color).frame(width: 7, height: 7)
                if store.workingCount > 1 {
                    Text("\(store.workingCount)").font(.system(size: 11, weight: .semibold, design: .rounded))
                }
            }
        }
    }

    /// Usage beside the Guy, always on: the session ("≈65%") or, when chosen, the week ("W 41%"), over the pace
    /// ("→130%", orange when it would run out first; exact readings only) or else the reset ("2:20", "Thu").
    private func usageBadge(_ w: UsageReading.Window, week: Bool, exact: Bool) -> some View {
        let pace = exact ? self.pace(w, week: week) : nil
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                if week { Text("W").foregroundStyle(.secondary) }
                Text("\(exact ? "" : "≈")\(Int(w.percent.rounded()))%").foregroundStyle(Self.usageTint(w.percent))
            }
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            if let pace {
                (pace.runsOutAt != nil ? Text(Image(systemName: "exclamationmark.triangle.fill")).font(.system(size: 7)) + Text(" ") : Text(""))
                    + Text("→\(Int(pace.projected.rounded()))%")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundColor(pace.runsOutAt != nil ? .orange : .secondary)
            } else if let reset = w.resetsAt, reset > Date() {
                Text(week ? reset.formatted(.dateTime.weekday(.abbreviated))
                          : reset.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        // The left ear is 84 pt: 12 + the Guy + this, clear of the camera.
        .frame(maxWidth: ui.earWidth - 12 - ui.geometry.barHeight * 0.66 - 12, alignment: .leading)
        .padding(.leading, 5)
        .help(badgeHelp(w, week: week, exact: exact, pace: pace))
    }

    /// The pace for a window: the week by your usual hours once they are learned, else by the time left.
    private func pace(_ w: UsageReading.Window, week: Bool, habits useHabits: Bool = true) -> UsagePace? {
        let now = Date()
        if week, useHabits, let habits = store.habits,
           let p = UsagePace.weekPace(percent: w.percent, resetsAt: w.resetsAt, now: now, habits: habits) { return p }
        return UsagePace.pace(percent: w.percent, resetsAt: w.resetsAt,
                              length: week ? UsageReading.weekLength : UsageReading.sessionLength, now: now)
    }

    private func badgeHelp(_ w: UsageReading.Window, week: Bool, exact: Bool, pace: UsagePace?) -> String {
        var text = week ? "Week: \(Int(w.percent.rounded()))% used."
                        : (exact ? "Session: \(Int(w.percent.rounded()))% used." : "Estimated session usage, about \(Int(w.percent.rounded()))%.")
        if let pace, let reset = w.resetsAt { text += " " + pace.sentence(resetsAt: reset, weekly: week) }
        if week, let budget = UsagePace.dailyBudget(percent: w.percent, resetsAt: w.resetsAt, now: Date()) { text += " " + budget }
        if store.exactUsageOn { text += " Option-click to switch between the session and the week." }
        if !week, store.notchWindow == .week { text += " Weekly usage unavailable, showing the session." }
        return text
    }

    /// Counts down beside the notch: purple to a limit that has chats paused, else to the
    /// session window's reset. Ticks by itself ("2h 14m", then "14:25").
    private func resetTimer(_ reset: Date, limit: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Store.shortCountdown(max(0, reset.timeIntervalSince(context.date))))
        }
        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
        .foregroundStyle(limit ? Color.purple : Color.white.opacity(0.85))
        .lineLimit(1)
        .help(limit ? "Time until the usage limit resets" : "Time until your session window resets")
    }

    static func usageTint(_ percent: Double) -> Color {
        percent >= 90 ? .red : percent >= 70 ? .orange : Color.white.opacity(0.85)
    }

    /// Time left until the usage limit resets, ticking by itself (no timers of ours).
    @ViewBuilder private var countdown: some View {
        Group {
            if let reset = store.limitResetsAt, reset > Date() {
                // Short enough for the space beside the notch: "1h 14m", then "14:25".
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Store.shortCountdown(reset.timeIntervalSince(context.date)))
                }
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            } else {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold))
            }
        }
        .foregroundStyle(.purple)
    }

    /// Shown while a usage limit has chats paused: countdown, auto-continue, continue now.
    private var limitBanner: some View {
        let paused = store.pausedSessions.count
        let chats = paused == 1 ? "1 chat paused" : "\(paused) chats paused"
        let reset = store.limitResetsAt
        return HStack(spacing: 9) {
            Image(systemName: "hourglass").foregroundStyle(.purple).font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                if let reset, reset > Date() {
                    (Text("Usage limit resets in ") + Text(timerInterval: Date()...reset, countsDown: true))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                } else {
                    Text("Usage limit has reset").font(.system(size: 12, weight: .semibold))
                }
                Text(store.continueStatus ?? bannerDetail(chats: chats))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if store.limitHasReset {
                Button("Continue now") {
                    if !Continuer.canType { Continuer.askToType() }
                    store.continuePaused()
                }
                    .buttonStyle(.borderedProminent).tint(.purple).controlSize(.small)
            }
            Button {
                store.autoContinueOn.toggle()
                if store.autoContinueOn { Continuer.askToType() }
            } label: {
                Label("Auto", systemImage: store.autoContinueOn ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help("Type \"continue\" into chats still paused a few minutes after the reset")
        }
        .padding(.horizontal, 10)
        .frame(height: UIState.bannerHeight - 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.14)))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func bannerDetail(chats: String) -> String {
        if store.limitHasReset {
            // Still paused after the reset: Claude did not pick these up by itself.
            return Continuer.canType ? "\(chats) · Continue now types continue in each"
                                     : "\(chats) · allow Buddy in Accessibility to continue them"
        }
        guard store.autoContinueOn else { return "\(chats) · Claude should resume them after the reset" }
        guard Continuer.canType else { return "\(chats) · allow Buddy in Accessibility to type" }
        if let at = store.autoContinueAt {
            return "\(chats) · backup types continue at \(at.formatted(date: .omitted, time: .shortened))"
        }
        return "\(chats) · backup types continue after the reset"
    }

    /// First run: Buddy sees nothing until Claude Code is told to report to it.
    private var setupBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "link").foregroundStyle(.orange).font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect Buddy to Claude Code").font(.system(size: 12, weight: .semibold))
                Text(ui.setupError ?? "Adds a small hook to ~/.claude/settings.json (backup kept)")
                    .font(.system(size: 11)).foregroundStyle(ui.setupError == nil ? .secondary : Color.orange).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Not now") { ui.deferSetup() }.buttonStyle(.bordered).controlSize(.small)
            Button("Connect") { ui.connect() }.buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
        }
        .padding(.horizontal, 10)
        .frame(height: UIState.bannerHeight - 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.14)))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    /// Plan usage at the top of the list, one full-width line per window. "≈" marks Buddy's local estimate.
    @ViewBuilder private var usageRow: some View {
        if let u = store.usage, u.session != nil || u.week != nil {
            VStack(spacing: 0) {
                if let s = u.session { meter("Session", s, approx: !u.exact, weekly: false) }
                if let w = u.week { meter("Week", w, approx: false, weekly: true) }
                if let o = u.opusWeek { meter("Opus", o, approx: false, weekly: true, habits: false) }
                if u.exact, let reset = u.week?.resetsAt {
                    WeekStrip(data: store.habitData, profile: store.habits?.profile,
                              windowStart: reset.addingTimeInterval(-UsageReading.weekLength),
                              caption: UsagePace.dailyBudget(percent: u.week?.percent ?? 0, resetsAt: reset, now: Date(), short: true),
                              help: UsagePace.dailyBudget(percent: u.week?.percent ?? 0, resetsAt: reset, now: Date()))
                        .frame(height: UIState.stripHeight)
                }
                if let line = UIState.accountLine(store) { accountRow(line) }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, UIState.usagePadding)
            .frame(height: ui.usageSpace)
        }
    }

    /// The Claude app's account on the left, the usual limit times on the right (Accounts.swift).
    private func accountRow(_ line: (account: String?, limits: String?, warn: Bool, help: String)) -> some View {
        HStack(spacing: 6) {
            if let account = line.account {
                (Text(Image(systemName: line.warn ? "exclamationmark.triangle.fill" : "person.crop.circle")).font(.system(size: 9))
                 + Text(" " + account))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(line.warn ? Color.orange : Color.secondary)
            }
            Spacer(minLength: 4)
            if let limits = line.limits {
                Text(limits).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .frame(height: UIState.usageRowHeight)
        .help(line.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.help)
    }

    /// Label, bar, percent, pace and reset in fixed columns. The bar's tick marks how much of the window's time has
    /// passed: fill beyond the tick is use ahead of an even pace.
    private func meter(_ label: String, _ w: UsageReading.Window, approx: Bool, weekly: Bool, habits: Bool = true) -> some View {
        let tint: Color = w.percent >= 90 ? .red : w.percent >= 70 ? .orange : Mood.working.color
        let length = weekly ? UsageReading.weekLength : UsageReading.sessionLength
        let reset = w.resetsAt.flatMap { $0 > Date() ? $0 : nil }
        let timeShare = reset.map { min(1, max(0, (length - $0.timeIntervalSinceNow) / length)) }
        let pace = approx ? nil : self.pace(w, week: weekly, habits: habits)
        let unsure = (pace?.band ?? 0) > 15
        return HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            UsageBar(percent: w.percent, tint: tint, timeShare: timeShare)
                .frame(height: 9)
            Text("\(approx ? "≈" : "")\(Int(w.percent.rounded()))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .frame(width: 38, alignment: .trailing)
            Text(pace.map { "→\(Int($0.projected.rounded()))%" } ?? "")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(pace?.runsOutAt != nil ? Color.orange : Color.secondary)
                .opacity(unsure ? 0.75 : 1)
                .frame(width: 40, alignment: .leading)
            // When the window would run out before it resets, this column says when (orange), else when it resets.
            if let out = pace?.runsOutAt {
                // Not color alone: a warning sign before the run-out time.
                (Text(Image(systemName: "exclamationmark.triangle.fill")).font(.system(size: 8))
                 + Text(" out " + (weekly ? out.formatted(.dateTime.weekday(.abbreviated).hour()) : out.formatted(date: .omitted, time: .shortened))))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.orange)
                    .frame(width: 84, alignment: .trailing)
            } else {
                Text(reset.map { weekly ? $0.formatted(.dateTime.weekday(.abbreviated).hour()) : $0.formatted(date: .omitted, time: .shortened) } ?? "")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                    .frame(width: 84, alignment: .trailing)
            }
        }
        .lineLimit(1)
        .frame(height: UIState.usageRowHeight)
        .help(meterHelp(label, w, approx: approx, weekly: weekly, pace: pace, reset: reset))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meterHelp(label, w, approx: approx, weekly: weekly, pace: pace, reset: reset))
    }

    private func meterHelp(_ label: String, _ w: UsageReading.Window, approx: Bool, weekly: Bool, pace: UsagePace?,
                           reset: Date?) -> String {
        var text = "\(label): \(approx ? "about " : "")\(Int(w.percent.rounded()))% used"
        if let reset { text += ", resets " + (weekly ? reset.formatted(.dateTime.weekday(.wide).hour().minute())
                                                      : reset.formatted(date: .omitted, time: .shortened)) }
        text += "."
        if let pace, let reset { text += " " + pace.sentence(resetsAt: reset, weekly: weekly) }
        if weekly, let budget = UsagePace.dailyBudget(percent: w.percent, resetsAt: reset, now: Date()) { text += " " + budget }
        if approx { text += " Estimated from your chats on this Mac (Settings → Usage for exact numbers)." }
        text += " The tick marks how much of the window's time has passed."
        return text
    }

    @ViewBuilder private var rows: some View {
        usageRow
        if ui.showSetup { setupBanner }
        if !store.pausedSessions.isEmpty { limitBanner }
        if store.ordered.isEmpty {
            Text("No Claude sessions right now")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: RowLayout.height)
                .padding(.bottom, 8)
        } else {
            list
        }
    }

    /// Set by the demo renderer: ImageRenderer cannot draw a ScrollView's contents.
    nonisolated(unsafe) static var plainListForImages = false

    /// Up to six rows tall, then it scrolls. Jumps back to the top when a session needs you.
    @ViewBuilder private var list: some View {
        if Self.plainListForImages {
            sessionRows.padding(.horizontal, 8).padding(.bottom, 8)
        } else {
            scrollingList
        }
    }

    private var scrollingList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                sessionRows
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ListScrollKey.self, value: -g.frame(in: .named("list")).minY)
                    })
            }
            .coordinateSpace(name: "list")
            .scrollIndicators(.automatic)
            .onPreferenceChange(ListScrollKey.self) { ui.listScrolled = $0 }
            .onChange(of: store.peek) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .top) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var sessionRows: some View {
        VStack(spacing: RowLayout.spacing) {
            ForEach(store.ordered) { s in
                let offset = ui.swipeID == s.id ? ui.swipeOffset : 0
                row(s)
                    .offset(x: offset)
                    .opacity(1 - min(Double(abs(offset)) / 260, 0.8))
                    // Click goes there and clears it; a sideways drag (mouse) clears it.
                    // Trackpad two-finger swipes arrive as scroll events, see PillHostingView.
                    .onTapGesture { store.open(s.id) }
                    .gesture(DragGesture(minimumDistance: 8)
                        .onChanged { ui.swipe(s.id, to: $0.translation.width) }
                        .onEnded { _ in ui.endSwipe() })
                    .contextMenu {
                        Button("Go to Session") { store.open(s.id) }
                        Button("Dismiss") { store.dismiss(s.id) }
                    }
                    .id(s.id)
            }
        }
    }

    private func row(_ s: Session) -> some View {
        let alert = s.mood == .attention
        let fresh = s.mood == .done && !s.acknowledged
        return HStack(alignment: .top, spacing: 9) {
            Circle().fill(s.mood.color).frame(width: 8, height: 8).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(s.name).font(.system(size: 12, weight: .semibold))
                    Text(s.prompt).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if s.mood >= .working, let started = s.turnStarted {
                        Text(started, style: .timer).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                    } else {
                        Text(s.updated, style: .relative).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
                Text(alert ? s.attentionText : s.activity)
                    .font(.system(size: 11.5))
                    .foregroundStyle(alert ? Color.orange : fresh ? Color.green : Color.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: RowLayout.height)
        .background(RoundedRectangle(cornerRadius: 10).fill(alert ? Color.orange.opacity(0.14) : .clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var menu: some View {
        Button("Settings…") { ui.openSettings?() }
        Button("Clear Finished Sessions") { store.clearFinished() }
        if store.exactUsageOn {
            Toggle("Show Weekly Usage in the Notch", isOn: Binding(
                get: { store.notchWindow == .week }, set: { store.notchWindow = $0 ? .week : .session }))
        }
        Button("Forget Usage Habits") { store.onForgetHabits?() }
        Divider()
        Button("Quit Buddy") { NSApp.terminate(nil) }
    }
}

/// The week in seven 24-hour slots from its start: this Mac's use each day (bars) against your usual day (outline,
/// once the habits are learned), on one scale; today's usual is the use up to now. Letters are each slot's weekday.
private struct WeekStrip: View {
    let data: HabitData?
    let profile: HabitProfile?
    let windowStart: Date
    let caption: String?
    let help: String?

    var body: some View {
        let now = Date()
        let actual = data?.slots(windowStart: windowStart) ?? Array(repeating: 0, count: 7)
        let usual: [Double] = (0..<7).map { i in
            guard let profile else { return 0 }
            let a = windowStart.addingTimeInterval(Double(i) * 86400), b = a.addingTimeInterval(86400)
            return profile.expected(from: a, to: now >= a && now < b ? now : b)   // today: the usual use up to now
        }
        let top = max(1, (actual + usual).max() ?? 1)
        let today = Int(floor(now.timeIntervalSince(windowStart) / 86400))
        // Columns line up with the meters above: the label, then the bars where the meter bars start.
        return HStack(alignment: .center, spacing: 8) {
            Text("Days").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<7, id: \.self) { i in
                    VStack(spacing: 2) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.06))
                            if usual[i] > 0 {
                                RoundedRectangle(cornerRadius: 2).stroke(Color.white.opacity(0.35), lineWidth: 1)
                                    .frame(height: max(2, 18 * usual[i] / top))
                            }
                            RoundedRectangle(cornerRadius: 2).fill(Mood.working.color.opacity(i > today ? 0.25 : 0.9))
                                .frame(height: actual[i] > 0 ? max(2, 18 * actual[i] / top) : 0)
                        }
                        .frame(height: 18)
                        .overlay(i == today ? RoundedRectangle(cornerRadius: 2).stroke(Color.white.opacity(0.6), lineWidth: 1) : nil)
                        Text(windowStart.addingTimeInterval(Double(i) * 86400).formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: 8, weight: .medium)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 168)
            Spacer(minLength: 8)
            if let caption {
                Text(caption).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
        }
        .help((help.map { $0 + " " } ?? "") + "Bars: this Mac's use each day of the week; outlines: your usual day.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week by day on this Mac. " + (help ?? ""))
    }
}

/// A thin usage bar with a tick at the share of the window's time that has passed.
private struct UsageBar: View {
    let percent: Double
    let tint: Color
    let timeShare: Double?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14)).frame(height: 5)
                Capsule().fill(tint).frame(width: max(5, w * min(max(percent, 0), 100) / 100), height: 5)
                if let t = timeShare {
                    Rectangle().fill(Color.white.opacity(0.75)).frame(width: 1.5, height: 9)
                        .offset(x: min(max(0, w * t - 0.75), w - 1.5))
                }
            }
            .frame(height: g.size.height)
        }
        .accessibilityElement()
        .accessibilityLabel("\(Int(percent.rounded())) percent used")
    }
}

private struct ListScrollKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}