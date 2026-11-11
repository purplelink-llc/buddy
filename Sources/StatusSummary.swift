import Foundation

/// The rows of the Status section in Settings, built from plain values so the wording can be
/// tested without a window. The view only renders what this returns.
struct StatusSummary: Equatable {
    enum Tone: Equatable { case good, attention, neutral }
    struct Row: Equatable {
        var label: String
        var value: String
        var tone: Tone
    }

    /// Whether the Accessibility row should offer the Open Privacy Settings action.
    var offersAccessibilitySettings: Bool
    var rows: [Row]

    /// `appVersion` stands in for the hook's version: the hook ships inside the app, and a
    /// connected hook is identical to the bundled copy.
    static func build(hookHealth: HookSetup.Health, appVersion: String,
                      lastEvent: Date?, now: Date,
                      accessibilityGranted: Bool,
                      exactUsageOn: Bool, usage: UsageReading?) -> StatusSummary {
        var rows: [Row] = []

        switch hookHealth {
        case .healthy:
            rows.append(Row(label: "Hook", value: "Connected (hook \(appVersion))", tone: .good))
        case .notInstalled:
            rows.append(Row(label: "Hook", value: "Not connected", tone: .attention))
        case .binaryStale:
            rows.append(Row(label: "Hook", value: "Out of date", tone: .attention))
        case .entryMissing, .binaryMissing:
            rows.append(Row(label: "Hook", value: "Needs repair", tone: .attention))
        }

        rows.append(Row(label: "Last event", value: lastEventText(lastEvent, now: now), tone: .neutral))

        rows.append(Row(label: "Accessibility",
                        value: accessibilityGranted ? "Granted" : "Not granted",
                        tone: accessibilityGranted ? .good : .attention))

        rows.append(usageRow(exactUsageOn: exactUsageOn, usage: usage))

        return StatusSummary(offersAccessibilitySettings: !accessibilityGranted, rows: rows)
    }

    /// Plain text for the Copy Diagnostics button: the Status rows plus versions and hardware.
    /// Generic labels only. It takes no chat titles, session or folder names, paths or prompt
    /// text, and the usage note (free text from a failed request) is left out, so nothing
    /// private can reach it.
    static func diagnostics(hookHealth: HookSetup.Health, appVersion: String, appBuild: String,
                            lastEvent: Date?, now: Date, accessibilityGranted: Bool,
                            exactUsageOn: Bool, usage: UsageReading?,
                            chatTitlesUnavailable: Bool, macOS: String, arch: String) -> String {
        let summary = build(hookHealth: hookHealth, appVersion: appVersion, lastEvent: lastEvent, now: now,
                            accessibilityGranted: accessibilityGranted, exactUsageOn: exactUsageOn, usage: usage)
        var lines = ["Buddy diagnostics", "App: \(appVersion) (\(appBuild))", "macOS: \(macOS)", "Hardware: \(arch)"]
        for row in summary.rows {
            let value = row.label == "Exact usage" ? usageRow(exactUsageOn: exactUsageOn, usage: usage, includeNote: false).value : row.value
            lines.append("\(row.label): \(value)")
        }
        lines.append("Chat titles: \(chatTitlesUnavailable ? "unavailable" : "available")")
        return lines.joined(separator: "\n")
    }

    static func lastEventText(_ date: Date?, now: Date) -> String {
        guard let date else { return "None since launch" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }
        return "\(hours / 24) d ago"
    }

    static func usageRow(exactUsageOn: Bool, usage: UsageReading?, includeNote: Bool = true) -> Row {
        guard exactUsageOn else {
            return Row(label: "Exact usage", value: "Off (estimate from chats on this Mac)", tone: .neutral)
        }
        guard let usage else {
            return Row(label: "Exact usage", value: "On, waiting for the first reading", tone: .neutral)
        }
        if usage.exact { return Row(label: "Exact usage", value: "On, reading from Anthropic", tone: .good) }
        if usage.needsSignIn {
            return Row(label: "Exact usage", value: "On, but Claude Code is not signed in", tone: .attention)
        }
        let why = includeNote ? usage.note.map { ": \($0)" } ?? "" : ""
        return Row(label: "Exact usage", value: "On, but unavailable\(why)", tone: .attention)
    }
}
