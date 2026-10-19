import Foundation

/// Watches the folder buddy-hook drops events into. The folder exists only while Buddy
/// runs, so the hook is a no-op (and Claude never waits) when Buddy is closed.
final class Inbox {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Buddy/inbox", isDirectory: true)

    let url: URL
    private let onEvents: ([HookEvent]) -> Void
    private var source: DispatchSourceFileSystemObject?

    init(url: URL = Inbox.defaultURL, onEvents: @escaping ([HookEvent]) -> Void) {
        self.url = url
        self.onEvents = onEvents
    }

    func start() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        drain()

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    /// Removes the folder so hooks stop writing while Buddy is closed.
    func stop() {
        source?.cancel()
        try? FileManager.default.removeItem(at: url)
    }

    func drain() {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.creationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys)) else { return }

        // The hook writes tmp.XXXXXX and renames it to tmp.XXXXXX.json when complete.
        let dated = files.filter { $0.pathExtension == "json" }.map { file in
            (file, (try? file.resourceValues(forKeys: keys).creationDate) ?? Date())
        }
        var events: [HookEvent] = []
        for (file, date) in dated.sorted(by: { $0.1 < $1.1 }) {
            let data = try? Data(contentsOf: file)
            try? fm.removeItem(at: file)
            if let data, let event = HookEvent(data: data, date: date) { events.append(event) }
        }
        if !events.isEmpty { onEvents(events) }
    }
}
