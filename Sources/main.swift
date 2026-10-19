import AppKit
import Combine
import Network
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    lazy var continuer = Continuer(store: store)
    /// Finds chats a usage limit paused before Buddy was listening. Used only on scanQueue.
    let pausedScan = PausedScan()
    let scanQueue = DispatchQueue(label: "llc.purplelink.Buddy.paused-scan", qos: .utility)
    var scanTimer: Timer?
    /// Retries chats a dropped connection stopped, once the network is back.
    let pathMonitor = NWPathMonitor()
    var online = true
    var retryTask: Task<Void, Never>?
    var ui: UIState!
    lazy var inbox = Inbox { [weak self] events in
        MainActor.assumeIsolated { self?.store.apply(events) }
    }
    var panel: NotchPanel!
    var changes: AnyCancellable?
    var frameSyncQueued = false
    var shrinkTask: Task<Void, Never>?
    var leaveTask: Task<Void, Never>?
    var expireTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        let me = Bundle.main.bundleIdentifier ?? ""
        guard NSRunningApplication.runningApplications(withBundleIdentifier: me).count <= 1,
              let geometry = NotchGeometry.current() else {
            NSApp.terminate(nil)
            return
        }
        ui = UIState(store: store, geometry: geometry)
        ui.refreshConnection()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        Log.note("started \(version), Accessibility \(Continuer.canType ? "on" : "off")")

        panel = NotchPanel(contentRect: ui.frame, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let host = PillHostingView(rootView: PillView(store: store, ui: ui))
        host.sizingOptions = []  // the window follows the pill, not SwiftUI's ideal size
        host.onHover = { [weak self] inside in self?.hover(inside) }
        host.onSwipe = { [weak self] fromTop, delta, phase in
            MainActor.assumeIsolated {
                guard let ui = self?.ui else { return }
                switch phase {
                case .began:
                    // Each gesture picks the row under the fingers afresh.
                    ui.cancelSwipe()
                    if let id = ui.rowID(atDistanceFromTop: fromTop) { ui.swipe(id, to: delta) }
                case .changed:
                    if let id = ui.swipeID { ui.swipe(id, by: delta) }
                case .ended:
                    ui.endSwipe()
                }
            }
        }
        panel.contentView = host
        panel.orderFrontRegardless()

        changes = ui.objectWillChange.sink { [weak self] in self?.queueFrameSync() }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let geometry = NotchGeometry.current() else { return }
                self.ui.geometry = geometry
            }
        }

        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.expire() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        expireTimer = timer

        store.onContinue = { [weak self] sessions, manual in self?.continuer.run(sessions, manual: manual) }
        store.onRetry = { [weak self] sessions in self?.continuer.retry(sessions) }
        store.onConnectionLost = { [weak self] in
            // The Mac thinks it is online (DNS or a brief blip): try again soon, waiting
            // longer each time; retryDisconnected caps the attempts.
            guard let self, self.online else { return }
            let attempt = self.store.disconnectedSessions.map(\.retries).max() ?? 0
            self.scheduleRetry(after: 20 * Double(attempt + 1), fresh: false)
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.networkChanged(up) } }
        }
        pathMonitor.start(queue: DispatchQueue(label: "llc.purplelink.Buddy.network", qos: .utility))
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRetry(after: 15, fresh: true) }
        }
        inbox.start()

        scanForPausedChats()
        let scan = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanForPausedChats() }
        }
        scan.tolerance = 120
        RunLoop.main.add(scan, forMode: .common)
        scanTimer = scan

        // Start at login by default; after the first launch the menu toggle decides.
        if !UserDefaults.standard.bool(forKey: "loginItemOffered") {
            UserDefaults.standard.set(true, forKey: "loginItemOffered")
            LoginItem.enabled = true
        }
    }

    private func networkChanged(_ up: Bool) {
        let wasOnline = online
        online = up
        guard up != wasOnline else { return }  // macOS also reports the state once at launch
        Log.note("network \(up ? "back" : "lost")")
        if up { scheduleRetry(after: 5, fresh: true) }
    }

    /// Retries stopped chats after `seconds`, if still online. A newer schedule replaces it.
    private func scheduleRetry(after seconds: Double, fresh: Bool) {
        guard !store.disconnectedSessions.isEmpty else { return }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.online else { return }
            Log.note("retrying \(self.store.disconnectedSessions.count) chats stopped by a dropped connection")
            self.store.retryDisconnected(fresh: fresh)
        }
    }

    private func scanForPausedChats() {
        let scan = pausedScan
        scanQueue.async {
            let found = scan.run()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.store.adoptScan(found)
                    self?.scheduleRetry(after: 10, fresh: false)  // chats that dropped just before launch
                }
            }
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        inbox.stop()
    }

    /// objectWillChange fires before the change lands, so read the new state next turn.
    private func queueFrameSync() {
        guard !frameSyncQueued else { return }
        frameSyncQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.frameSyncQueued = false
            self?.syncFrame()
        }
    }

    /// Grow at once; shrink after the collapse animation so the pill is never clipped.
    private func syncFrame() {
        let target = ui.frame
        let current = panel.frame
        guard target != current else { shrinkTask?.cancel(); return }
        let cover = current.union(target)
        if cover != current { panel.setFrame(cover, display: true) }
        guard cover != target else { shrinkTask?.cancel(); return }
        shrinkTask?.cancel()
        shrinkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            self.panel.setFrame(self.ui.frame, display: true)
        }
    }

    private func hover(_ inside: Bool) {
        if inside {
            leaveTask?.cancel()
            leaveTask = nil
            if !ui.hovering { ui.hovering = true }
            store.markFinishedSeen()
        } else if ui.hovering, leaveTask == nil {
            // A short grace period so brushing past the edge doesn't snap it shut.
            leaveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.ui.hovering = false
                self?.leaveTask = nil
            }
        }
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()