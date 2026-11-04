import AppKit
import SwiftUI
import UserNotifications

/// Buddy's small Settings window (right-click the pill, then Settings…).
struct SettingsView: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState
    /// Claude Code's signed-in account, read when exact usage is on.
    @State private var account: ClaudeAccount?
    @State private var checkedAccount = false
    @State private var confirmSignOut = false
    @State private var notificationsDenied = false

    static let releasesURL = URL(string: "https://github.com/purplelink-llc/buddy/releases/latest")!

    var body: some View {
        // Re-read permission and connection state while the window is open, so a change made
        // in System Settings shows up without reopening it.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            Form {
                Section("General") {
                    Toggle("Open at login", isOn: Binding(get: { LoginItem.enabled }, set: { LoginItem.enabled = $0 }))
                    Toggle("Sound when a chat needs you", isOn: $store.soundForAttention)
                    Toggle("Sound when a chat finishes", isOn: $store.soundForDone)
                }
                Section {
                    Toggle("Continue paused chats automatically", isOn: Binding(
                        get: { store.autoContinueOn },
                        set: { on in
                            store.autoContinueOn = on
                            if on, !Continuer.canType { Continuer.askToType() }
                        }))
                    Toggle("Keep the Mac awake until they continue", isOn: $store.keepAwakeOn)
                        .disabled(!store.autoContinueOn)
                } header: {
                    Text("Usage limits")
                } footer: {
                    Text("About a minute after each chat's limit resets, Buddy types \"continue\" into it (up to three tries). It can't type into a locked Mac, so it retries when you unlock; keep awake stops the Mac idle-locking while chats wait.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Retry chats when you're back online", isOn: $store.retryConnectionsOn)
                } header: {
                    Text("Dropped connections")
                } footer: {
                    Text("Buddy presses Try again (or types \"continue\") in a chat a dropped connection stopped, at most three times.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Exact usage from Anthropic", isOn: $store.exactUsageOn)
                    if store.exactUsageOn, checkedAccount, let account {
                        LabeledContent("Account") {
                            HStack {
                                Text(account.orgName.map { "\(account.email) · \($0)" } ?? account.email)
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Menu("Change") {
                                    Button("Switch Account…") { signIn(switching: true) }
                                    Button("Sign Out…", role: .destructive) { confirmSignOut = true }
                                }
                                .fixedSize()
                            }
                        }
                    }
                    if let note = store.usage?.note {
                        HStack(alignment: .firstTextBaseline) {
                            Text(note).font(.caption).foregroundStyle(.orange)
                            Spacer(minLength: 8)
                            if store.usage?.needsSignIn == true {
                                Button("Sign In…") { signIn(switching: false) }
                                    .help("Opens Terminal to run claude auth login, which finishes in your browser")
                            }
                        }
                    }
                } header: {
                    Text("Usage")
                } footer: {
                    Text("Off: an estimate from your chats on this Mac (≈). On: exact session and weekly usage from Anthropic, using Claude Code's sign-in. Besides the daily update check, this is Buddy's only network use.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Usage habits") {
                        if let data = store.habitData, data.learnedDays >= 21 {
                            Text("Learned from \(Int(data.learnedDays)) days on this Mac")
                        } else {
                            Text("Learning: \(Int(store.habitData?.learnedDays ?? 0)) of 21 days")
                        }
                    }
                    if let acc = store.habitData?.midWeekAccuracy {
                        Text("Mid-week forecasts were off by \(Int(acc.points.rounded())) points on average (\(acc.weeks) week\(acc.weeks == 1 ? "" : "s")).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Warn me when the week will run out early", isOn: Binding(
                        get: { store.warnWeekEarly },
                        set: { on in
                            store.warnWeekEarly = on
                            if on { WeekWarning.requestPermission() }
                        }))
                        .disabled(!store.exactUsageOn)
                    if store.warnWeekEarly, notificationsDenied {
                        Text("Notifications are off for Buddy in System Settings → Notifications.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button("Forget Usage Habits") { store.onForgetHabits?() }
                } header: {
                    Text("Pace")
                } footer: {
                    Text("Buddy learns your usual hours from Claude Code on this Mac (a small file in Application Support, never sent anywhere) to forecast the week. The warning is one notification a week, sent only when even the low end of the forecast runs out over a day before the reset.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .task(id: store.warnWeekEarly) {
                    let settings = await UNUserNotificationCenter.current().notificationSettings()
                    notificationsDenied = settings.authorizationStatus == .denied
                }
                Section("Claude Code") {
                    LabeledContent("Hook") {
                        HStack {
                            Text(ui.connected ? "Connected" : "Not connected")
                                .foregroundStyle(ui.connected ? Color.green : Color.orange)
                            Button(ui.connected ? "Disconnect" : "Connect") {
                                ui.connected ? ui.disconnect() : ui.connect()
                            }
                        }
                    }
                    LabeledContent("Accessibility") {
                        HStack {
                            Text(Continuer.canType ? "Allowed" : "Not allowed")
                                .foregroundStyle(Continuer.canType ? Color.green : Color.orange)
                            Button("Open Settings") { Self.openAccessibilitySettings() }
                        }
                    }
                    Text("Accessibility is needed only for Continue now, Auto, and retrying dropped connections in the Claude app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { ui.automaticUpdates },
                        set: { on in ui.automaticUpdates = on; ui.setAutomaticUpdates?(on) }))
                    HStack {
                        Button("Check for Updates…") {
                            if let check = ui.checkForUpdates { check() } else { NSWorkspace.shared.open(Self.releasesURL) }
                        }
                        Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL]) }
                    }
                }
            }
            .formStyle(.grouped)
        }
        // A grouped Form scrolls, so it has no natural size of its own: give it a range and let
        // the window (resizable, size remembered) pick within it.
        .frame(minWidth: 400, idealWidth: 460, maxWidth: .infinity, minHeight: 280, idealHeight: 560, maxHeight: .infinity)
        .task(id: store.exactUsageOn) { await refreshAccount() }
        .confirmationDialog("Sign Claude Code out on this Mac?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) {
                Task { @MainActor in
                    _ = await ClaudeAccount.signOut()
                    await refreshAccount()
                    store.onRefreshUsage?()
                }
            }
        } message: {
            Text("Buddy uses Claude Code's sign-in, so this also signs out claude in Terminal. The Claude app keeps its own sign-in.")
        }
        .onAppear { ui.refreshConnection() }
    }

    /// Runs the sign-in, then checks again every few seconds for up to five minutes so the
    /// note clears as soon as Claude Code has saved the new sign-in.
    private func signIn(switching: Bool) {
        let before = account
        ExactUsage.openSignIn(switching: switching)
        Task { @MainActor in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(5))
                guard store.exactUsageOn else { return }
                await refreshAccount()
                store.onRefreshUsage?()
                // Done once a (different) account is signed in and usage reads.
                if account != nil, account != before || !switching, store.usage?.needsSignIn != true { return }
            }
        }
    }

    private func refreshAccount() async {
        guard store.exactUsageOn else { checkedAccount = false; return }
        account = await ClaudeAccount.current()
        checkedAccount = true
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
