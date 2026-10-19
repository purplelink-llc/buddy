import AppKit
import SwiftUI

// Renders README and website images from Buddy's real views with made-up sessions, so no
// screenshot ever shows a real desktop or real chats. Built and run by `./build.sh demo`
// (with HOME pointed at a throwaway folder); writes PNGs into the directory given.

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "design/demo")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
UserDefaults.standard.set(true, forKey: "setupDeferred")  // no first-run banner in the images
PillView.plainListForImages = true

func event(_ json: String, at date: Date = Date()) -> HookEvent {
    HookEvent(data: Data(("com.apple.Terminal\t\tttys001\n" + json).utf8), date: date)!
}

@MainActor
func render(_ name: String, height: CGFloat, expanded: Bool, _ events: [HookEvent], autoOn: Bool = false) {
    let defaults = UserDefaults(suiteName: "buddy-demo-\(UUID().uuidString)")!
    defaults.set(autoOn, forKey: "autoTypeContinue")
    let store = Store(defaults: defaults, sound: { _ in })
    store.apply(events)
    let screen = NSRect(x: 0, y: 0, width: 760, height: height)
    let ui = UIState(store: store, geometry: NotchGeometry(screenFrame: screen, notchWidth: 186, barHeight: 32))
    ui.hovering = expanded

    let scene = ZStack(alignment: .top) {
        LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.24), Color(red: 0.05, green: 0.05, blue: 0.09)],
                       startPoint: .top, endPoint: .bottom)
        Rectangle().fill(.white.opacity(0.08)).frame(height: 32)
        PillView(store: store, ui: ui)
    }
    .frame(width: screen.width, height: screen.height)

    let renderer = ImageRenderer(content: scene)
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        fatalError("could not render \(name)")
    }
    try! png.write(to: outDir.appendingPathComponent("\(name).png"))
    print("wrote \(name).png")
}

/// Every mood, large, for checking the character's drawing.
@MainActor
func renderCharacterSheet() {
    let moods: [(Mood, String)] = [(.idle, "idle"), (.working, "working"), (.attention, "needs you"), (.done, "done"), (.paused, "paused")]
    let sheet = HStack(spacing: 36) {
        ForEach(moods, id: \.1) { mood, label in
            VStack(spacing: 14) {
                Guy(mood: mood, size: 120)
                Text(label).font(.system(size: 15)).foregroundStyle(.white.opacity(0.7))
            }
        }
    }
    .padding(40)
    .background(.black)
    let renderer = ImageRenderer(content: sheet)
    renderer.scale = 2
    let png = NSBitmapImageRep(data: renderer.nsImage!.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    try! png.write(to: outDir.appendingPathComponent("character.png"))
    print("wrote character.png")
}

MainActor.assumeIsolated {
    renderCharacterSheet()
    let now = Date()
    let earlier = now.addingTimeInterval(-192)

    // The list: one session needs you, one is working, one just finished.
    render("list", height: 260, expanded: true, [
        event(#"{"hook_event_name":"UserPromptSubmit","session_id":"a","cwd":"/Users/me/Code/acme","prompt":"fix the flaky login test"}"#, at: earlier),
        event(#"{"hook_event_name":"PermissionRequest","session_id":"a","tool_name":"Bash","tool_input":{"description":"Push the fix to GitHub"}}"#),
        event(#"{"hook_event_name":"UserPromptSubmit","session_id":"b","cwd":"/Users/me/Code/widgets","prompt":"add a dark mode toggle"}"#, at: now.addingTimeInterval(-41)),
        event(#"{"hook_event_name":"PreToolUse","session_id":"b","tool_name":"Edit","tool_input":{"file_path":"/x/SettingsView.swift"}}"#),
        event(#"{"hook_event_name":"UserPromptSubmit","session_id":"c","cwd":"/Users/me/Code/notes","prompt":"write the release notes"}"#, at: earlier),
        event(#"{"hook_event_name":"Stop","session_id":"c"}"#, at: now.addingTimeInterval(-1)),
    ])

    // A usage limit: countdown, paused chats, auto-continue on.
    let reset = now.addingTimeInterval(83 * 60 + 12)
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "h:mma"
    let resetText = f.string(from: reset).lowercased()
    let zone = TimeZone.current.identifier
    var limitEvents: [HookEvent] = []
    for (id, name, prompt) in [("p1", "acme", "migrate the billing tables"), ("p2", "widgets", "refactor the settings screen")] {
        limitEvents.append(event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(id)","cwd":"/Users/me/Code/\#(name)","prompt":"\#(prompt)"}"#, at: now.addingTimeInterval(-600)))
        limitEvents.append(event(#"{"hook_event_name":"StopFailure","session_id":"\#(id)","error":"rate_limit","last_assistant_message":"You've hit your session limit · resets \#(resetText) (\#(zone))"}"#, at: now.addingTimeInterval(-300)))
    }
    render("limit", height: 230, expanded: true, limitEvents, autoOn: true)

    // Collapsed: working, and counting down to a reset.
    render("collapsed-working", height: 70, expanded: false, [
        event(#"{"hook_event_name":"UserPromptSubmit","session_id":"w","cwd":"/Users/me/Code/acme","prompt":"go"}"#),
    ])
    render("collapsed-limit", height: 70, expanded: false, limitEvents)
}
