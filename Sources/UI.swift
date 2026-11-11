import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

/// Where the notch is on the screen Buddy lives on. Screens without a notch get a
/// small bar at the top centre instead.
struct NotchGeometry: Equatable {
    var screenFrame: NSRect
    var centerX: CGFloat
    var notchWidth: CGFloat
    var barHeight: CGFloat

    init(screen: NSScreen) {
        screenFrame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = right.minX - left.maxX
            centerX = left.maxX + notchWidth / 2
            barHeight = screen.safeAreaInsets.top
        } else {
            notchWidth = 0
            centerX = screen.frame.midX
            barHeight = 26
        }
    }

    /// A made-up screen, for rendering demo images.
    init(screenFrame: NSRect, notchWidth: CGFloat, barHeight: CGFloat) {
        self.screenFrame = screenFrame
        self.centerX = screenFrame.midX
        self.notchWidth = notchWidth
        self.barHeight = barHeight
    }

    /// The notched screen if there is one, else the menu-bar screen; nil with no display.
    static func current() -> NotchGeometry? {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first
        else { return nil }
        return NotchGeometry(screen: screen)
    }
}

@MainActor
final class UIState: ObservableObject {
    @Published var geometry: NotchGeometry
    @Published var hovering = false {
        // Re-check the permission each time the list opens; no polling.
        didSet { if hovering && !oldValue { refreshAccessibility() } }
    }
    /// Whether Buddy may type into other apps; refreshed when the list opens.
    @Published private(set) var accessibilityTrusted = true
    func refreshAccessibility() {
        let now = Continuer.canType
        if now != accessibilityTrusted { accessibilityTrusted = now }
    }
    var accessibilityNotice: AccessibilityNotice? {
        AccessibilityNotice.needed(autoOn: store.autoContinueOn, continueNow: store.limitHasReset,
                                   trusted: accessibilityTrusted)
    }
    let store: Store
    private var forward: AnyCancellable?

    init(store: Store, geometry: NotchGeometry) {
        self.store = store
        self.geometry = geometry
        forward = store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    // MARK: Connecting to Claude Code

    let setup = HookSetup()
    /// Opens the Settings window (set by the app delegate).
    var openSettings: (() -> Void)?
    /// Sparkle, set by the app delegate (kept out of this file so tests build without it).
    var checkForUpdates: (() -> Void)?
    var setAutomaticUpdates: ((Bool) -> Void)?
    @Published var automaticUpdates = true
    @Published private(set) var connected = true
    @Published private(set) var hookHealth: HookSetup.Health = .healthy
    private var healthSignature = ""
    private var repairDismissed = false
    @Published private(set) var setupError: String?
    /// "Not now" on the first-run banner.
    private var setupDeferred: Bool {
        get { UserDefaults.standard.bool(forKey: "setupDeferred") }
        set { UserDefaults.standard.set(newValue, forKey: "setupDeferred") }
    }

    /// The first-run banner: shown until Buddy is connected or you say not now.
    /// Also shown again when a connected hook later breaks (entry removed, file missing or stale),
    /// until you say not now (for this run of Buddy only).
    var showSetup: Bool {
        switch hookHealth {
        case .healthy: return false
        case .notInstalled: return !setupDeferred
        default: return !repairDismissed
        }
    }

    func refreshConnection() {
        connected = setup.isConnected
        let health = setup.health
        if health != hookHealth {
            if health.needsRepair { repairDismissed = false }
            hookHealth = health
        }
        healthSignature = setup.changeSignature
    }

    /// Launch check: after an app update, quietly reinstalls a stale hook (no banner); otherwise
    /// the normal health check decides what to show. Records the version for the next launch.
    func launchHealthCheck(currentVersion: String, defaults: UserDefaults = .standard) {
        let key = "lastSeenAppVersion"
        let action = HookSetup.launchAction(lastSeenVersion: defaults.string(forKey: key),
                                            currentVersion: currentVersion, health: setup.health)
        if action == .silentRefresh, let bundled = setup.bundledHook {
            do { try setup.installHook(from: bundled) } catch { Log.note("could not update the hook: \(error)") }
        }
        defaults.set(currentVersion, forKey: key)
        refreshConnection()
    }

    /// Runs about once a minute: does the real check only when one of the files changed.
    func pollHookHealth() {
        guard setup.changeSignature != healthSignature else { return }
        refreshConnection()
    }

    func connect() {
        do {
            try setup.connect()
            setupError = nil
        } catch {
            setupError = "Could not connect: \(error.localizedDescription)"
            Log.note("connect failed: \(error)")
        }
        refreshConnection()
    }

    func disconnect() {
        do { try setup.disconnect() } catch { Log.note("disconnect failed: \(error)") }
        refreshConnection()
    }

    func deferSetup() {
        if hookHealth.needsRepair { repairDismissed = true } else { setupDeferred = true }
        objectWillChange.send()
    }

    /// Opens on hover, and on its own for a while when a session needs you or finishes.
    var expanded: Bool { hovering || store.peek != nil || showSetup }
    /// Hidden entirely while nothing is going on; always there once usage is known.
    var shown: Bool { expanded || store.hasNews || showsUsage }

    /// Usage sits beside the Guy, so the ears grow to fit it (both sides, to stay centred).
    var showsUsage: Bool { store.shownUsage != nil }
    /// What the countdown right of the notch counts to: a usage limit that has chats paused
    /// (`limit`), or else the session window's reset.
    var resetCountdown: (date: Date, limit: Bool)? {
        let now = Date()
        if !store.pausedSessions.isEmpty, let reset = store.limitResetsAt, reset > now { return (reset, true) }
        if let reset = store.usage?.session?.resetsAt, reset > now { return (reset, false) }
        return nil
    }
    var earWidth: CGFloat { showsUsage || resetCountdown != nil ? 84 : 46 }
    var collapsedWidth: CGFloat { geometry.notchWidth > 0 ? geometry.notchWidth + 2 * earWidth : 120 + 2 * (earWidth - 46) }

    var size: CGSize {
        guard expanded else { return CGSize(width: collapsedWidth, height: geometry.barHeight) }
        return CGSize(width: max(collapsedWidth, 420),
                      height: geometry.barHeight + usageSpace + bannerSpace + RowLayout.listHeight(rows: store.ordered.count) + 8)
    }

    /// The plan-usage rows at the top of the open list: one line per window (session, week), never wrapped.
    static let usageRowHeight: CGFloat = 20
    static let usagePadding: CGFloat = 4
    static let stripHeight: CGFloat = 40
    var usageSpace: CGFloat {
        guard let u = store.usage else { return 0 }
        let rows = (u.session != nil ? 1 : 0) + (u.week != nil ? 1 : 0) + (u.opusWeek != nil ? 1 : 0)
        // The week strip's room is kept whenever exact usage has a week, so the panel does not jump when data arrives.
        let strip = u.exact && u.week?.resetsAt != nil ? Self.stripHeight : 0
        let account = Self.accountLine(store) == nil ? 0 : 1
        return rows == 0 ? 0 : CGFloat(rows + account) * Self.usageRowHeight + 2 * Self.usagePadding + strip
    }

    /// The line under the usage rows: which account the Claude app is on, and when the limit usually hits. Warns
    /// when exact usage reads a different account (Claude Code's sign-in) than the app's chats run on.
    static func accountLine(_ store: Store) -> (account: String?, limits: String?, warn: Bool, help: String)? {
        let tag = store.accountTag
        let warn = store.exactUsageOn && tag?.mismatch == true
        let account = tag?.app.map { warn ? "\($0) · usage is \(tag?.code ?? "")" : $0 }
        let times = store.usualLimitTimes.map { LimitTimes.label($0) }
        let limits = times.isEmpty ? nil : "Limit usually ~" + times.joined(separator: ", ")
        guard account != nil || limits != nil else { return nil }
        var help: [String] = []
        if let app = tag?.app { help.append("The Claude app is signed in as \(app).") }
        if warn, let code = tag?.code {
            help.append("Exact usage comes from Claude Code's own sign-in, \(code), so these numbers are for \(code), not \(tag?.app ?? "").")
        }
        if !times.isEmpty {
            help.append("Over the last four weeks your session limit usually hit around \(times.joined(separator: " and ")).")
        }
        return (account, limits, warn, help.joined(separator: " "))
    }

    /// The usage-limit banner above the list, when chats are paused.
    static let bannerHeight: CGFloat = 50
    static let noticeHeight: CGFloat = 34
    var bannerSpace: CGFloat {
        (store.pausedSessions.isEmpty ? 0 : Self.bannerHeight) + (showSetup ? Self.bannerHeight : 0)
            + (accessibilityNotice == nil ? 0 : Self.bannerHeight)
            + (store.jumpNotice == nil ? 0 : Self.noticeHeight)
    }

    // MARK: Swipe to clear

    /// Swipe this far sideways to clear a row.
    static let swipeDistance: CGFloat = 80

    @Published private(set) var swipeID: String?
    @Published private(set) var swipeOffset: CGFloat = 0
    /// How far the list is scrolled. Not published: it changes every frame while scrolling
    /// and only swipe hit-testing reads it.
    var listScrolled: CGFloat = 0

    func swipe(_ id: String, to offset: CGFloat) {
        swipeID = id
        swipeOffset = offset
    }

    func swipe(_ id: String, by delta: CGFloat) {
        swipe(id, to: (swipeID == id ? swipeOffset : 0) + delta)
    }

    func cancelSwipe() {
        swipeID = nil
        swipeOffset = 0
    }

    func endSwipe() {
        guard let id = swipeID else { return }
        guard abs(swipeOffset) >= Self.swipeDistance else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { swipeOffset = 0 }
            return
        }
        let direction: CGFloat = swipeOffset > 0 ? 1 : -1
        withAnimation(.easeOut(duration: 0.16)) { swipeOffset = direction * 460 }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            self?.store.dismiss(id)
            self?.swipeID = nil
            self?.swipeOffset = 0
        }
    }

    /// The row under a point measured from the top of the pill, using the same layout
    /// constants the view uses.
    func rowID(atDistanceFromTop y: CGFloat) -> String? {
        guard expanded else { return nil }
        let rows = store.ordered
        return RowLayout.index(atDistanceIntoList: y - geometry.barHeight - usageSpace - bannerSpace, scrolled: listScrolled,
                               count: rows.count)
            .map { rows[$0].id }
    }

    /// The window's frame: the pill, or just the notch itself while hidden (dead space,
    /// so it blocks nothing) so hovering the notch can still open the list.
    var frame: NSRect {
        let s = shown ? size : CGSize(width: geometry.notchWidth > 0 ? geometry.notchWidth : 120,
                                      height: geometry.barHeight)
        return NSRect(x: (geometry.centerX - s.width / 2).rounded(), y: geometry.screenFrame.maxY - s.height,
                      width: s.width.rounded(), height: s.height)
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosts the pill: acts on the first click without focusing the window first, and
/// reports hover through one tracking area (no system-wide mouse monitoring).
final class PillHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    enum SwipePhase { case began, changed, ended }
    /// A sideways two-finger trackpad swipe: (distance from the top of the pill, delta, phase).
    var onSwipe: ((CGFloat, CGFloat, SwipePhase) -> Void)?
    private var hoverArea: NSTrackingArea?
    private var swiping = false

    override func scrollWheel(with event: NSEvent) {
        // Only finger-driven, mostly sideways gestures; momentum after lift-off is ignored.
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return super.scrollWheel(with: event) }
        if event.phase == .began {
            swiping = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        guard swiping else { return super.scrollWheel(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        let fromTop = isFlipped ? point.y : bounds.height - point.y
        let phase: SwipePhase = event.phase == .began ? .began
            : (event.phase == .ended || event.phase == .cancelled) ? .ended : .changed
        onSwipe?(fromTop, event.scrollingDeltaX, phase)
        if phase == .ended { swiping = false }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === hoverArea { onHover?(true) } else { super.mouseEntered(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === hoverArea { onHover?(false) } else { super.mouseExited(with: event) }
    }
}

/// Open at Login. The status is asked once and then remembered: the right-click menu is
/// rebuilt on every redraw, and each fresh ask is a round trip to a system service.
@MainActor
enum LoginItem {
    private static var known: Bool?

    static var enabled: Bool {
        get {
            if let known { return known }
            let status = SMAppService.mainApp.status == .enabled
            known = status
            return status
        }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.note("could not change Open at Login: \(error)")
            }
            known = SMAppService.mainApp.status == .enabled
        }
    }
}

/// The opt-in heads-up (docs/designs/weekly-usage-pace.md, v4.1): one notification a week, by your usual hours only,
/// when even the low end of the forecast's range runs out more than a day before the week resets.
@MainActor
enum WeekWarning {
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        // Buddy has no Dock icon and is often frontmost through Settings; show the banner anyway.
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
            async -> UNNotificationPresentationOptions { [.banner, .sound] }
    }
    private static let delegate = Delegate()

    static func setUp() { UNUserNotificationCenter.current().delegate = delegate }

    static func requestPermission() {
        NSApp.activate(ignoringOtherApps: true)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func check(store: Store) {
        guard store.warnWeekEarly, store.usage?.exact == true, let w = store.usage?.week, let reset = w.resetsAt,
              let habits = store.habits,
              let pace = UsagePace.weekPace(percent: w.percent, resetsAt: reset, now: Date(), habits: habits),
              let out = pace.runsOutAt, reset.timeIntervalSince(out) > 86400,
              pace.projected - (pace.band ?? 0) > 100 else { return }
        let week = Int(reset.timeIntervalSince1970 / 3600)
        guard abs(store.warnedWeekReset - week) > 1 else { return }   // once a week; an hour of reset jitter is the same week
        store.warnedWeekReset = week
        let days = Int((reset.timeIntervalSince(out) / 86400).rounded())
        let content = UNMutableNotificationContent()
        content.title = "Weekly limit"
        content.body = "At your usual pace, your weekly limit runs out around "
            + out.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            + ", about \(days) day\(days == 1 ? "" : "s") before it resets."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "week-\(week)", content: content, trigger: nil))
        Log.note("sent the weekly-limit heads-up")
    }
}

/// The opt-in limit-time heads-up (docs/designs/account-and-limit-times.md): one notification up to an hour before a
/// time of day the session limit usually hits, only when the session is already at least 40% used and no chat is
/// paused by a limit.
@MainActor
enum LimitWarning {
    static func check(store: Store, now: Date = Date()) {
        guard store.warnUsualLimit, store.pausedSessions.isEmpty,
              let session = store.usage?.session, session.percent >= 40, session.percent < 100,
              let at = LimitTimes.upcoming(store.usualLimitTimes, now: now),
              abs(store.warnedLimitAt - at.timeIntervalSince1970) > 60 else { return }
        store.warnedLimitAt = at.timeIntervalSince1970
        let content = UNMutableNotificationContent()
        content.title = "Session limit"
        content.body = "You usually hit your session limit around " + at.formatted(date: .omitted, time: .shortened)
            + ". This session is at \(Int(session.percent.rounded()))%"
            + (store.accountTag?.app.map { " on \($0)." } ?? ".")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "limit-\(Int(at.timeIntervalSince1970))",
                                                                     content: content, trigger: nil))
        Log.note("sent the usual-limit heads-up")
    }
}
