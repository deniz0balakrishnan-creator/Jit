// `jit notify --tool claude|codex [--event finished|working|idle]`: tell the running Jit app
// that a tool finished a turn (the default), started working on a prompt, or stopped without
// finishing (an interrupt, an error, the session ending).
//
// Run from a hook, it also passes along the hook's session id (read from the JSON on stdin)
// and its parent processes, so Jit knows which app the tool runs in.
//
// Always exits 0 and prints nothing, even on bad arguments or when Jit isn't running, so it
// can never break, block, or add to the prompt of the Claude Code or Codex hook that runs it.
import Foundation

var options: [String: String] = [:]
let args = Array(CommandLine.arguments.dropFirst())
if args.first == "notify" {
    var i = 1
    while i + 1 < args.count, args[i].hasPrefix("--") {
        options[String(args[i].dropFirst(2))] = args[i + 1]
        i += 2
    }
}
guard let tool = options["tool"], ["claude", "codex"].contains(tool),
      ["finished", "working", "idle"].contains(options["event"] ?? "finished") else {
    FileHandle.standardError.write("usage: jit notify --tool claude|codex [--event finished|working|idle]\n".data(using: .utf8)!)
    exit(0)
}

/// The hook's JSON on stdin; skipped when run by hand from a terminal, and never waited on for long.
func hookInput() -> [String: Any] {
    guard isatty(0) == 0 else { return [:] }
    var data = Data()
    var pfd = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
    var chunk = [UInt8](repeating: 0, count: 4096)
    while data.count < 1 << 20, poll(&pfd, 1, 300) > 0 {
        let n = read(0, &chunk, chunk.count)
        if n <= 0 { break }
        data.append(contentsOf: chunk[0..<n])
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

/// This process's parents, nearest first, up to (not including) launchd.
func parentProcesses() -> [Int] {
    var pids: [Int] = []
    var pid = getppid()
    while pid > 1 && pids.count < 32 {
        pids.append(Int(pid))
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
        pid = info.kp_eproc.e_ppid
    }
    return pids
}

var message: [String: Any] = ["tool": tool, "event": options["event"] ?? "finished", "pids": parentProcesses()]
if let session = hookInput()["session_id"] as? String { message["session"] = session }

let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Jit/jit.sock").path

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &addr.sun_path) { buf in
    socketPath.utf8CString.withUnsafeBytes { buf.copyBytes(from: $0.prefix(buf.count - 1)) }
}
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
if connected == 0, var line = try? JSONSerialization.data(withJSONObject: message) {
    line.append(UInt8(ascii: "\n"))
    _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
}
close(fd)
exit(0)
