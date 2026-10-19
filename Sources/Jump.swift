import AppKit

/// Where a click on a session goes: the exact Claude chat, Terminal/iTerm2 tab or editor
/// window when Buddy knows it, otherwise the app. Only apps that are already running are
/// brought forward; a hook event can never make Buddy launch something.
enum Jump: Equatable {
    case desktopChat(sessionID: String)
    case terminalTab(bundleID: String, tty: String)
    case folder(bundleID: String, path: String)
    case app(bundleID: String)
    case none

    static let claudeApp = "com.anthropic.claudefordesktop"
    static let terminal = "com.apple.Terminal"
    static let iTerm = "com.googlecode.iterm2"
    /// Editors that focus the window already showing a folder when asked to open it.
    static let editors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.exafunction.windsurf", "dev.zed.Zed",
    ]

    static func target(host: Host, cwd: String) -> Jump {
        let id = host.bundleID
        if id == claudeApp, matches(host.desktopSessionID, #"^local_[A-Za-z0-9-]{1,64}$"#) {
            return .desktopChat(sessionID: host.desktopSessionID)
        }
        if id == terminal || id == iTerm, matches(host.tty, #"^ttys?[0-9]{1,4}$"#) {
            return .terminalTab(bundleID: id, tty: host.tty)
        }
        if editors.contains(id), cwd.hasPrefix("/") { return .folder(bundleID: id, path: cwd) }
        return id.isEmpty ? .none : .app(bundleID: id)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    @MainActor
    func perform() {
        switch self {
        case .desktopChat(let sessionID):
            // The Claude app's own deep link: opens that Code session's chat.
            guard Self.running(Self.claudeApp) != nil,
                  let url = URL(string: "claude://code/continue?session=\(sessionID)") else { return }
            NSWorkspace.shared.open(url)
        case .terminalTab(let bundleID, let tty):
            guard Self.running(bundleID) != nil else { return }
            if !Self.selectTab(bundleID: bundleID, tty: tty) { Self.activate(bundleID) }
        case .folder(let bundleID, let path):
            guard let app = Self.running(bundleID), let appURL = app.bundleURL else { return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: config)
        case .app(let bundleID):
            Self.activate(bundleID)
        case .none:
            break
        }
    }

    private static func running(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    private static func activate(_ bundleID: String) {
        guard let url = running(bundleID)?.bundleURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    /// Brings the window and tab running on `tty` to the front. macOS asks once for
    /// permission to control Terminal or iTerm2. `tty` is validated as ttysNNN above.
    @MainActor
    private static func selectTab(bundleID: String, tty: String) -> Bool {
        let device = "/dev/\(tty)"
        let source: String
        if bundleID == terminal {
            source = """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(device)" then
                            set miniaturized of w to false
                            set selected of t to true
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        } else {
            source = """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(device)" then
                                select w
                                select t
                                select s
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { Log.note("could not select the terminal tab: \(error)") }
        return result?.booleanValue == true
    }
}
