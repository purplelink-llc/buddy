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

/// The little guy: a Claude-coloured squircle with eyes. Glances around while Claude
/// works, hops when it needs you, smiles when it is done, blinks when idle.
struct Guy: View {
    let mood: Mood
    let size: CGFloat
    /// Hop eagerly; after the first seconds a waiting guy hops only now and then.
    var urgent = false

    @State private var blink = false
    @State private var look: CGFloat = 0
    @State private var hop = false

    private let skin = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                .fill(skin.gradient)
            HStack(spacing: size * 0.18) { eye; eye }
                .offset(y: -size * 0.03)
        }
        .frame(width: size, height: size * 0.88)
        .offset(y: hop ? -size * 0.16 : 0)
        .task(id: "\(mood.rawValue)-\(urgent)") { await animate() }
    }

    @ViewBuilder private var eye: some View {
        if mood == .done {
            HappyEye().stroke(.white, style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round))
                .frame(width: size * 0.2, height: size * 0.12)
        } else {
            let wide = mood == .attention
            Capsule().fill(.white)
                .frame(width: size * 0.2, height: size * (wide ? 0.32 : 0.27))
                .overlay(
                    Circle().fill(.black)
                        .frame(width: size * 0.11)
                        .offset(x: look * size * 0.04, y: wide ? -size * 0.03 : 0)
                )
                .scaleEffect(y: blink ? 0.1 : 1)
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
            Spacer()
            badge.padding(.trailing, 14)
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

    /// Time left until the usage limit resets, ticking by itself (no timers of ours).
    @ViewBuilder private var countdown: some View {
        Group {
            if let reset = store.limitResetsAt, reset > Date() {
                Text(timerInterval: Date()...reset, countsDown: true)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
            } else {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold))
            }
        }
        .foregroundStyle(.purple)
        .frame(maxWidth: 44)
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

    @ViewBuilder private var rows: some View {
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
        Toggle("Sounds", isOn: Binding(get: { store.soundsOn }, set: { store.soundsOn = $0 }))
        Toggle("Open at Login", isOn: Binding(get: { LoginItem.enabled }, set: { LoginItem.enabled = $0 }))
        Button("Clear Finished Sessions") { store.clearFinished() }
        if ui.connected {
            Button("Disconnect from Claude Code") { ui.disconnect() }
        } else {
            Button("Connect to Claude Code") { ui.connect() }
        }
        Divider()
        Button("Quit Buddy") { NSApp.terminate(nil) }
    }
}

private struct ListScrollKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}