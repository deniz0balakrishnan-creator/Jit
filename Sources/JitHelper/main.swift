// `jit notify --tool claude|codex`: tell the running Jit app that a tool finished.
//
// Always exits 0, even on bad arguments or when Jit isn't running, so it can never
// break the Claude Code or Codex hook that runs it.
import Foundation

let args = CommandLine.arguments.dropFirst()
guard args.count == 3, args.first == "notify", args.dropFirst().first == "--tool",
      let tool = args.last, ["claude", "codex"].contains(tool) else {
    FileHandle.standardError.write("usage: jit notify --tool claude|codex\n".data(using: .utf8)!)
    exit(0)
}

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
if connected == 0 {
    let line = "{\"tool\":\"\(tool)\"}\n"
    _ = line.withCString { write(fd, $0, strlen($0)) }
}
close(fd)
exit(0)
