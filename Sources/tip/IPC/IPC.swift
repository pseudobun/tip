import Darwin
import Foundation

/// CLI ↔ app over a Unix socket that only this user can reach: the directory is 0700, the socket
/// 0600, and the app checks every peer's uid. A request is one command (`run focus west`, `query`…)
/// sent until EOF; the reply is one JSON object, then the app closes the connection.
enum IPC {
    static let dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: AppPaths.bundleID, directoryHint: .isDirectory)
    static var socketPath: String { dir.appending(path: "tip.sock").path }

    /// Where the CLI looks: its own tip, then a dev build (`just dev`, `<bundle id>.dev`) while the
    /// release one is quit, so `tip` and scripts keep working with either running.
    static var clientSocketPaths: [String] {
        guard !AppPaths.isDev else { return [socketPath] }
        let dev = dir.deletingLastPathComponent().appending(path: AppPaths.bundleID + ".dev", directoryHint: .isDirectory)
        return [socketPath, dev.appending(path: "tip.sock").path]
    }

    /// A reply carrying this key holds an object the IPC thread encodes as the reply's "json"
    /// string (pretty, sorted), so the main thread only builds it.
    static let jsonObjectKey = "_jsonObject"

    static func prettyJSON(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static let maxRequest = 64 * 1024
    static let maxReply = 16 * 1024 * 1024

    // MARK: - Client

    enum ClientError: Error { case notRunning, failed(String) }

    /// Sends `command` and returns the app's reply.
    static func send(_ command: String, timeout: TimeInterval) -> Result<[String: Any], ClientError> {
        for path in clientSocketPaths {
            let r = send(command, timeout: timeout, socketPath: path)
            if case .failure(.notRunning) = r { continue }
            return r
        }
        return .failure(.notRunning)
    }

    static func send(_ command: String, timeout: TimeInterval, socketPath: String) -> Result<[String: Any], ClientError> {
        guard FileManager.default.fileExists(atPath: socketPath) else { return .failure(.notRunning) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.failed("socket: \(String(cString: strerror(errno)))")) }
        defer { close(fd) }
        configure(fd, timeout: timeout)
        guard var addr = address(socketPath) else { return .failure(.failed("socket path too long")) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            return errno == ECONNREFUSED || errno == ENOENT ? .failure(.notRunning)
                : .failure(.failed("connect: \(String(cString: strerror(errno)))"))
        }
        guard writeAll(fd, Data(command.utf8)) else { return .failure(.failed("write: \(String(cString: strerror(errno)))")) }
        shutdown(fd, SHUT_WR)
        guard let data = readAll(fd, limit: maxReply), !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.failed("tip did not answer"))
        }
        return .success(obj)
    }

    /// Sends `command` and hands every line the app writes back to `onLine` until it closes the
    /// connection. Returns why it ended.
    static func stream(_ command: String, onLine: (String) -> Void) -> ClientError {
        // The first tip that answers; a dropped connection ends the stream (callers reconnect).
        for path in clientSocketPaths where FileManager.default.fileExists(atPath: path) {
            var connected = false
            let end = stream(command, socketPath: path) { connected = true; onLine($0) }
            if case .notRunning = end, !connected { continue }
            return end
        }
        return .notRunning
    }

    /// Lets another thread end a stream blocked in `read`: `cancel` shuts the socket down.
    final class StreamHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32 = -1
        private var cancelled = false

        /// false: cancelled before the stream started.
        fileprivate func attach(_ fd: Int32) -> Bool {
            lock.withLock {
                guard !cancelled else { return false }
                self.fd = fd
                return true
            }
        }

        fileprivate func detach() { lock.withLock { fd = -1 } }

        func cancel() {
            lock.withLock {
                cancelled = true
                if fd >= 0 { shutdown(fd, SHUT_RDWR) }
            }
        }
    }

    static func stream(_ command: String, socketPath: String, handle: StreamHandle? = nil, onLine: (String) -> Void) -> ClientError {
        guard FileManager.default.fileExists(atPath: socketPath) else { return .notRunning }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed("socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        if let handle {
            guard handle.attach(fd) else { return .failed("cancelled") }
        }
        // Runs before the close above: a late cancel never shuts down a reused descriptor.
        defer { handle?.detach() }
        configure(fd, timeout: 5)
        guard var addr = address(socketPath) else { return .failed("socket path too long") }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return .notRunning }
        guard writeAll(fd, Data(command.utf8)) else { return .failed("write: \(String(cString: strerror(errno)))") }
        shutdown(fd, SHUT_WR)
        var tv = timeval(tv_sec: 0, tv_usec: 0) // events can be minutes apart
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pending = Data()
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return .notRunning }
            pending.append(contentsOf: buffer[0..<n])
            while let nl = pending.firstIndex(of: 0x0a) {
                onLine(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...nl)
            }
        }
    }

    // MARK: - Server

    final class Server {
        private let handler: (String) -> [String: Any]
        private let subscribe: (Int32, String) -> Void
        private var listener: Int32 = -1

        /// `handler` runs on the main thread with the request text and returns the reply.
        /// `subscribe` (main thread) takes over the connection of a `subscribe …` request.
        init(handler: @escaping (String) -> [String: Any], subscribe: @escaping (Int32, String) -> Void) {
            self.handler = handler
            self.subscribe = subscribe
        }

        func start() throws {
            try IPC.prepareDirectory()
            let path = IPC.socketPath
            guard var addr = IPC.address(path) else { throw IPCError("socket path too long: \(path)") }
            try IPC.clearSocketPath(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw IPCError("socket: \(String(cString: strerror(errno)))") }
            // Created 0600 from the start: no window where another user could connect.
            let old = umask(0o177)
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            umask(old)
            guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 128) == 0 else {
                let message = String(cString: strerror(errno))
                close(fd)
                throw IPCError("bind \(path): \(message)")
            }
            listener = fd
            let thread = Thread { [weak self] in self?.acceptLoop(fd) }
            thread.name = "tip.ipc"
            thread.start()
        }

        func stop() {
            stopped = true
            guard listener >= 0 else { return }
            let fd = listener
            listener = -1
            close(fd)
            unlink(IPC.socketPath)
        }

        private var stopped = false
        /// Connections being served; more than this and new ones wait in the backlog.
        private let slots = DispatchSemaphore(value: 64)

        private func acceptLoop(_ fd: Int32) {
            var backoff: useconds_t = 10_000
            while true {
                slots.wait()
                let client = accept(fd, nil, nil)
                if client < 0 {
                    let err = errno
                    slots.signal()
                    if stopped || err == EBADF || err == EINVAL { return } // closed by stop()
                    if err != EINTR && err != ECONNABORTED {
                        // Out of descriptors (EMFILE/ENFILE) or memory: wait and try again; giving
                        // up here would leave the CLI dead until tip restarts.
                        Log.app.error("ipc: accept: \(String(cString: strerror(err)), privacy: .public)")
                        usleep(backoff)
                        backoff = min(backoff * 2, 1_000_000)
                    }
                    continue
                }
                backoff = 10_000
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else { close(client); return }
                    self.serve(client)
                    self.slots.signal()
                }
            }
        }

        private func serve(_ fd: Int32) {
            var keep = false
            defer { if !keep { close(fd) } }
            // Fails with EINVAL when the client already hung up; SIGPIPE is ignored process-wide
            // (AppDelegate), so the write below then just fails with EPIPE.
            IPC.configure(fd, timeout: 5)
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                Log.app.error("ipc: refused a peer of uid \(uid)")
                return
            }
            guard let data = IPC.readAll(fd, limit: IPC.maxRequest) else {
                Log.app.error("ipc: unreadable or oversized request")
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            if text == "subscribe" || text.hasPrefix("subscribe ") {
                keep = true
                DispatchQueue.main.async { [subscribe] in subscribe(fd, text) }
                return
            }
            var reply = DispatchQueue.main.sync { handler(text) }
            if let object = reply.removeValue(forKey: IPC.jsonObjectKey) {
                reply["json"] = IPC.prettyJSON(object)
            }
            let out = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data("{}".utf8)
            _ = IPC.writeAll(fd, out)
        }
    }

    struct IPCError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    // MARK: - Helpers

    /// The socket's directory: ours, a real directory, 0700.
    static func prepareDirectory() throws {
        let path = dir.path
        if mkdir(path, 0o700) != 0, errno != EEXIST { throw IPCError("mkdir \(path): \(String(cString: strerror(errno)))") }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else {
            throw IPCError("\(path) is not a directory owned by this user")
        }
        if st.st_mode & 0o777 != 0o700, chmod(path, 0o700) != 0 {
            throw IPCError("chmod \(path): \(String(cString: strerror(errno)))")
        }
    }

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        return addr
    }

    /// Per-socket options. Returns false when they could not be set, which on macOS is what an
    /// accepted socket whose peer already closed reports (EINVAL): such a socket raises SIGPIPE
    /// on write, so processes that serve sockets must ignore SIGPIPE rather than rely on this.
    @discardableResult
    static func configure(_ fd: Int32, timeout: TimeInterval) -> Bool {
        var on: Int32 = 1
        let a = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        let b = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let c = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return a == 0 && b == 0 && c == 0
    }

    /// Makes room for the socket at `path`: removes an old socket, and moves anything else that
    /// sits there (a directory, a file) aside instead of failing to bind for the whole session.
    static func clearSocketPath(_ path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        if (st.st_mode & S_IFMT) == S_IFSOCK || (st.st_mode & S_IFMT) == S_IFLNK {
            if unlink(path) != 0 { throw IPCError("unlink \(path): \(String(cString: strerror(errno)))") }
            return
        }
        let aside = path + ".stale-\(getpid())-\(Int(Date().timeIntervalSince1970))"
        if rename(path, aside) != 0 { throw IPCError("move aside \(path): \(String(cString: strerror(errno)))") }
        Log.app.error("ipc: \(path, privacy: .public) was not a socket; moved it to \(aside, privacy: .public)")
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }

    /// Reads until EOF; nil on error, timeout or more than `limit` bytes.
    static func readAll(_ fd: Int32, limit: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { return nil }
            if n == 0 { return data }
            data.append(contentsOf: buffer[0..<n])
            if data.count > limit { return nil }
        }
    }
}
