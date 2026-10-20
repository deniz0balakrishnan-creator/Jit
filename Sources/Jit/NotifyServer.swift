import Foundation

/// Listens on `~/Library/Application Support/Jit/jit.sock` for one-line JSON messages
/// from the `jit` helper, like `{"tool":"claude","event":"finished","session":"…","pids":[…]}`.
final class NotifyServer {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Jit")

    private let onMessage: ([String: Any]) -> Void
    private var listener: DispatchSourceRead?

    init(onMessage: @escaping ([String: Any]) -> Void) {
        self.onMessage = onMessage
    }

    func start() {
        let path = Self.directory.appendingPathComponent("jit.sock").path
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        unlink(path)  // a stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            path.utf8CString.withUnsafeBytes { buf.copyBytes(from: $0.prefix(buf.count - 1)) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            NSLog("Jit: couldn't listen on %@: %s", path, strerror(errno))
            close(fd)
            return
        }
        chmod(path, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.accept(on: fd) }
        source.resume()
        listener = source
    }

    private func accept(on fd: Int32) {
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else { return }
        var received = Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: .main)
        source.setEventHandler { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 256)
            let n = read(client, &chunk, chunk.count)
            if n > 0 && received.count < 4096 {
                received.append(contentsOf: chunk[0..<n])
                return
            }
            // The helper closed its end (or sent too much): handle what arrived.
            source.setEventHandler(handler: nil)
            source.cancel()
            self?.handle(received)
        }
        source.setCancelHandler { close(client) }
        source.resume()
    }

    private func handle(_ data: Data) {
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            onMessage(message)
        }
    }
}
