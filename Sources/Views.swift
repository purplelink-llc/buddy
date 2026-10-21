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
        HStack {
            Guy(mood: store.overallMood, size: ui.geometry.barHeight * 0.66, urgent: store.peek != nil)
                .padding(.leading, 12)
            if ui.showsUsage, let s = store.usage?.session { usageBadge(s, approx: store.usage?.exact == false) }
            Spacer()
            // The space beside the notch is 46 pt; the badge never reaches under the camera.
            badge.frame(maxWidth: 33, alignment: .trailing).padding(.trailing, 7)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.openTop() }
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
            countdown
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

    /// Session usage beside the Guy, always on: percent over the reset time ("≈65%" / "2:20").
    private func usageBadge(_ w: UsageReading.Window, approx: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(approx ? "≈" : "")\(Int(w.percent.rounded()))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Self.usageTint(w.percent))
            if let reset = w.resetsAt, reset > Date() {
                Text(reset.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        // The left ear is 84 pt: 12 + the Guy + this, clear of the camera.
        .frame(maxWidth: ui.earWidth - 12 - ui.geometry.barHeight * 0.66 - 12, alignment: .leading)
        .padding(.leading, 5)
        .help(store.usage?.exact == true ? "Session usage (exact) and when it resets" : "Estimated session usage and when it resets")
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

    /// Plan usage at the top of the list. "≈" marks Buddy's local estimate.
    @ViewBuilder private var usageRow: some View {
        if let u = store.usage, u.session != nil || u.week != nil {
            HStack(spacing: 16) {
                if let s = u.session { meter("Session", s, approx: !u.exact, weekly: false) }
                if let w = u.week { meter("Week", w, approx: false, weekly: true) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(height: UIState.usageHeight)
            .help(u.exact ? "Exact usage from Anthropic" : "Estimated from your chats on this Mac (Settings → Usage for exact numbers)")
        }
    }

    private func meter(_ label: String, _ w: UsageReading.Window, approx: Bool, weekly: Bool) -> some View {
        let tint: Color = w.percent >= 90 ? .red : w.percent >= 70 ? .orange : Mood.working.color
        return HStack(spacing: 6) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ProgressView(value: min(max(w.percent, 0), 100), total: 100).progressViewStyle(.linear).tint(tint).frame(width: 56)
            Text("\(approx ? "≈" : "")\(Int(w.percent.rounded()))%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
            if let reset = w.resetsAt, reset > Date() {
                Text(weekly ? reset.formatted(.dateTime.weekday(.abbreviated).hour()) : reset.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
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
        Divider()
        Button("Quit Buddy") { NSApp.terminate(nil) }
    }
}

private struct ListScrollKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}