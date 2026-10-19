import Foundation

/// Connects Buddy to Claude Code from inside the app: copies the bundled buddy-hook to
/// ~/.claude/hooks and adds one entry per event to ~/.claude/settings.json. Other hooks are
/// left alone, a timestamped backup is written before any change, and nothing is written
/// when nothing would change. scripts/hooks.py does the same for development builds.
struct HookSetup {
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                         "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"]

    let claudeDir: URL
    /// The hook binary inside the app bundle.
    let bundledHook: URL?

    init(claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true),
         bundledHook: URL? = Bundle.main.url(forAuxiliaryExecutable: "buddy-hook")) {
        self.claudeDir = claudeDir
        self.bundledHook = bundledHook
    }

    var settingsURL: URL { claudeDir.appendingPathComponent("settings.json") }
    var hookURL: URL { claudeDir.appendingPathComponent("hooks/buddy-hook") }

    var isConnected: Bool {
        guard let settings = try? readSettings() else { return false }
        return Self.hasBuddy(settings)
    }

    func connect() throws {
        guard let bundledHook else { throw SetupError.missingHook }
        try installHook(from: bundledHook)
        try write(Self.merged(try readSettings()))
    }

    func disconnect() throws {
        try write(Self.unmerged(try readSettings()))
        try? FileManager.default.removeItem(at: hookURL)
    }

    /// Keeps the installed hook in step with the app after an update.
    func refreshHookIfConnected() {
        guard isConnected, let bundledHook,
              !FileManager.default.contentsEqual(atPath: bundledHook.path, andPath: hookURL.path) else { return }
        do { try installHook(from: bundledHook) } catch { Log.note("could not update the hook: \(error)") }
    }

    enum SetupError: Error { case missingHook, unreadableSettings }

    // MARK: - Settings JSON (pure, tested)

    static func command(for event: String) -> String { "\"$HOME/.claude/hooks/buddy-hook\" \(event)" }

    static func isBuddy(_ group: Any) -> Bool {
        let hooks = (group as? [String: Any])?["hooks"] as? [[String: Any]] ?? []
        return hooks.contains { ($0["command"] as? String)?.contains("buddy-hook") == true }
    }

    static func hasBuddy(_ settings: [String: Any]) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return hooks.values.contains { ($0 as? [Any])?.contains(where: isBuddy) == true }
    }

    static func unmerged(_ settings: [String: Any]) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            let kept = (value as? [Any] ?? []).filter { !isBuddy($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    static func merged(_ settings: [String: Any]) -> [String: Any] {
        var settings = unmerged(settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            let entry: [String: Any] = ["hooks": [["type": "command", "command": command(for: event), "timeout": 5]]]
            hooks[event] = (hooks[event] as? [Any] ?? []) + [entry]
        }
        settings["hooks"] = hooks
        return settings
    }

    // MARK: - Files

    private func readSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }  // no settings yet
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SetupError.unreadableSettings
        }
        return object
    }

    private func write(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        let current = (try? readSettings()) ?? [:]
        guard !NSDictionary(dictionary: current).isEqual(to: settings) else { return }
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsURL.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            var backup = claudeDir.appendingPathComponent("settings.json.bak-buddy-\(stamp)")
            var n = 2
            while fm.fileExists(atPath: backup.path) {  // two changes in the same second
                backup = claudeDir.appendingPathComponent("settings.json.bak-buddy-\(stamp)-\(n)")
                n += 1
            }
            try fm.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: settingsURL, options: .atomic)
    }

    private func installHook(from source: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: hookURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = hookURL.appendingPathExtension("new")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: source, to: staged)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        if fm.fileExists(atPath: hookURL.path) {
            _ = try fm.replaceItemAt(hookURL, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: hookURL)
        }
    }
}
