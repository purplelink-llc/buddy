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

    /// What is wrong, if anything, between Buddy, ~/.claude/settings.json and the installed hook.
    enum Health: Equatable {
        case healthy
        /// Neither the settings entry nor the hook file: Buddy was never connected (or was disconnected).
        case notInstalled
        /// The hook file is there but settings.json no longer points at it.
        case entryMissing
        /// settings.json points at the hook but the file is gone.
        case binaryMissing
        /// The installed hook differs from the copy bundled in this version of Buddy.
        case binaryStale

        /// A state that was fine once and needs repair (as opposed to a first run).
        var needsRepair: Bool { self != .healthy && self != .notInstalled }
    }

    /// Pure and cheap: reads settings.json and compares two small files. Takes the folders it
    /// looks at, so tests can point it at a scratch home.
    static func health(claudeDir: URL, bundledHook: URL?) -> Health {
        let setup = HookSetup(claudeDir: claudeDir, bundledHook: bundledHook)
        let fm = FileManager.default
        let entry = setup.isConnected
        let binary = fm.fileExists(atPath: setup.hookURL.path)
        switch (entry, binary) {
        case (false, false): return .notInstalled
        case (false, true): return .entryMissing
        case (true, false): return .binaryMissing
        case (true, true):
            if let bundledHook, fm.fileExists(atPath: bundledHook.path),
               !fm.contentsEqual(atPath: bundledHook.path, andPath: setup.hookURL.path) { return .binaryStale }
            return .healthy
        }
    }

    /// What to do about the hook health at launch.
    enum LaunchAction: Equatable { case nothing, silentRefresh, showBanner }

    /// Pure. A stale hook binary right after an app update (or on the first launch with no
    /// recorded version) is refreshed silently, as before hook health existed. A stale hook
    /// with the version unchanged was changed by something else, so it gets the banner.
    /// A missing settings entry or missing binary always gets the banner: Buddy never
    /// silently re-adds an entry the user removed.
    static func launchAction(lastSeenVersion: String?, currentVersion: String, health: Health) -> LaunchAction {
        switch health {
        case .healthy, .notInstalled: return .nothing
        case .entryMissing, .binaryMissing: return .showBanner
        case .binaryStale: return lastSeenVersion != currentVersion ? .silentRefresh : .showBanner
        }
    }

    var health: Health { Self.health(claudeDir: claudeDir, bundledHook: bundledHook) }

    /// Changes whenever settings.json, the installed hook or the bundled hook changes, so a
    /// periodic check can skip the real work while nothing moved.
    var changeSignature: String {
        [settingsURL, hookURL, bundledHook].compactMap { $0 }.map { url -> String in
            let a = try? FileManager.default.attributesOfItem(atPath: url.path)
            let t = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return "\(url.lastPathComponent):\(t):\((a?[.size] as? Int) ?? -1)"
        }.joined(separator: "|")
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

    func installHook(from source: URL) throws {
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
