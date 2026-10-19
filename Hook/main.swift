import Darwin

// buddy-hook: hands one Claude Code hook event to Buddy. Claude waits for hooks, so this
// is a single native process (no shell, no mktemp/cat/mv). The inbox folder exists only
// while Buddy runs; otherwise this drains stdin and exits.
//
// Usage (from settings.json): buddy-hook <EventName>
// Writes <inbox>/tmp.XXXXXX.json: one header line "host \t desktop-session \t tty",
// then the JSON Claude sent. PostToolUse is cut to its session id, since Buddy only needs
// to know the tool ran, and tool output can be megabytes.

func env(_ key: String) -> String {
    guard let value = getenv(key) else { return "" }
    return String(cString: value).filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }
}

func readStdin() -> [UInt8] {
    var data: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(STDIN_FILENO, &buffer, buffer.count)
        if n <= 0 { break }
        data.append(contentsOf: buffer[0..<n])
    }
    return data
}

/// The terminal this Claude session runs in (e.g. "ttys003"), or "" for app-hosted sessions.
func controllingTTY() -> String {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return "" }
    let dev = info.kp_eproc.e_tdev
    guard dev != -1, let name = devname(dev, mode_t(S_IFCHR)) else { return "" }
    let tty = String(cString: name)
    return tty.hasPrefix("tty") ? tty : ""
}

/// The first "session_id":"…" value. Claude writes it as the first key, before any tool data.
func sessionID(in data: [UInt8]) -> String? {
    let key = Array("\"session_id\":\"".utf8)
    let limit = min(data.count, 4096)
    guard limit > key.count else { return nil }
    for start in 0...(limit - key.count) where data[start..<start + key.count].elementsEqual(key) {
        var end = start + key.count
        var id: [UInt8] = []
        while end < limit, data[end] != UInt8(ascii: "\"") { id.append(data[end]); end += 1 }
        let allowed = id.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 }
        return allowed && !id.isEmpty && id.count <= 128 ? String(decoding: id, as: UTF8.self) : nil
    }
    return nil
}

func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n <= 0 { return false }
        offset += n
    }
    return true
}

var payload = readStdin()
let inbox = env("HOME") + "/Library/Application Support/Buddy/inbox"
var info = stat()
guard stat(inbox, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { exit(0) }

let event = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
if event == "PostToolUse", let id = sessionID(in: payload) {
    payload = Array("{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"\(id)\"}".utf8)
}

let header = [env("__CFBundleIdentifier"), env("CLAUDE_CODE_HOST_SESSION_ID"), controllingTTY()]
    .joined(separator: "\t") + "\n"

var template = Array((inbox + "/tmp.XXXXXX").utf8CString)
let fd = mkstemp(&template)
guard fd >= 0 else { exit(0) }
let ok = writeAll(fd, Array(header.utf8)) && writeAll(fd, payload)
close(fd)
let tmp = String(cString: template)
if ok { rename(tmp, tmp + ".json") } else { unlink(tmp) }
exit(0)
