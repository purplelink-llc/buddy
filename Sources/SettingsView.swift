import AppKit
import SwiftUI

/// Buddy's small Settings window (right-click the pill, then Settings…).
struct SettingsView: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState

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
                } header: {
                    Text("Usage limits")
                } footer: {
                    Text("About a minute after each chat's limit resets, Buddy types \"continue\" into it, and tries again up to three times if it is still paused.")
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
                    if let note = store.usage?.note {
                        Text(note).font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Usage")
                } footer: {
                    Text("Off: Buddy estimates session usage from your chats on this Mac (shown with ≈). On: Buddy reads Claude Code's sign-in from your keychain and asks Anthropic every few minutes for exact session and weekly usage. Apart from the daily update check, this is the only time Buddy uses the network.")
                        .font(.caption).foregroundStyle(.secondary)
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
        // A grouped Form scrolls, so it has no natural height of its own: size the window.
        .frame(width: 460, height: 900)
        .onAppear { ui.refreshConnection() }
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
