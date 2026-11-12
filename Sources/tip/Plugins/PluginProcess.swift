import Darwin
import Foundation
import TipCore

/// One running plugin program: JSON-RPC 2.0 lines on stdin/stdout, stderr to the log. Spawned as
/// its own responsible process, so it never inherits tip's permissions.
@MainActor
final class PluginProcess {
    let id: String
    let directory: URL
    let executable: URL
    private(set) var pid: pid_t = 0
    private var input: FileHandle?
    private var outputs: [FileHandle] = []
    private var exitSource: DispatchSourceProcess?
    private var nextID = 1
    private var pending: [Int: (RPCMessage) -> Void] = [:]
    var onMessage: ((RPCMessage) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onLog: ((String) -> Void)?
    /// Lines longer than the budget allows.
    var onViolation: ((String) -> Void)?

    var isRunning: Bool { pid != 0 }

    init(id: String, directory: URL, executable: URL) {
        self.id = id
        self.directory = directory
        self.executable = executable
    }

    func start() throws {
        var toChild: [Int32] = [0, 0], fromChild: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        guard pipe(&toChild) == 0, pipe(&fromChild) == 0, pipe(&errors) == 0 else {
            throw ConfigProblem("pipe: \(String(cString: strerror(errno)))")
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, toChild[0], 0)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errors[1], 2)
        for fd in toChild + fromChild + errors { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        Self.disclaim(&attributes)
        let path = executable.path
        var cArgs = [strdup(path), nil]
        var cEnv = Self.environment(directory: directory, id: id).map { strdup($0) } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var child: pid_t = 0
        let status = posix_spawn(&child, path, &actions, &attributes, &cArgs, &cEnv)
        close(toChild[0])
        close(fromChild[1])
        close(errors[1])
        guard status == 0 else {
            for fd in [toChild[1], fromChild[0], errors[0]] { close(fd) }
            throw ConfigProblem("cannot start \(executable.lastPathComponent): \(String(cString: strerror(status)))")
        }
        pid = child
        input = FileHandle(fileDescriptor: toChild[1], closeOnDealloc: true)
        let stdout = FileHandle(fileDescriptor: fromChild[0], closeOnDealloc: true)
        let stderr = FileHandle(fileDescriptor: errors[0], closeOnDealloc: true)
        outputs = [stdout, stderr]
        Self.readLines(stdout, limit: PluginBudget.maxMessageBytes) { [weak self] line in
            guard let self else { return }
            if line.count > PluginBudget.maxMessageBytes { self.onViolation?("message over 64 KB"); return }
            guard let msg = RPCMessage.decode(line) else { self.onLog?("not JSON-RPC: \(String(decoding: line.prefix(200), as: UTF8.self))"); return }
            if let id = msg.id, msg.method == nil, let done = self.pending.removeValue(forKey: id) { done(msg); return }
            self.onMessage?(msg)
        }
        Self.readLines(stderr, limit: 16 * 1024) { [weak self] line in
            self?.onLog?(String(decoding: line, as: UTF8.self))
        }
        let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            var st: Int32 = 0
            waitpid(child, &st, 0)
            MainActor.assumeIsolated {
                guard let self, self.pid == child else { return }
                self.cleanup()
                self.onExit?(st)
            }
        }
        source.resume()
        exitSource = source
    }

    func stop() {
        guard pid != 0 else { return }
        notify("shutdown", [:])
        let victim = pid
        cleanup()
        kill(victim, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { kill(victim, SIGKILL) }
    }

    private func cleanup() {
        exitSource?.cancel()
        exitSource = nil
        pid = 0
        input = nil
        outputs.forEach { $0.readabilityHandler = nil }
        outputs = []
        let waiting = pending
        pending = [:]
        for (id, done) in waiting { done(RPCMessage(id: id, error: .init(code: -32000, message: "plugin exited"))) }
    }

    func notify(_ method: String, _ params: JSONValue) {
        write(RPCMessage(method: method, params: params))
    }

    func request(_ method: String, _ params: JSONValue, timeout: TimeInterval = PluginBudget.requestTimeout,
                 done: @escaping (RPCMessage) -> Void) {
        let id = nextID
        nextID += 1
        pending[id] = done
        write(RPCMessage(id: id, method: method, params: params))
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let done = self.pending.removeValue(forKey: id) else { return }
                done(RPCMessage(id: id, error: .init(code: -32001, message: "timed out after \(Int(timeout)) s")))
                self.onViolation?("\(method) timed out")
            }
        }
    }

    private func write(_ m: RPCMessage) {
        guard let input else { return }
        let data = m.line
        // A full pipe must not block the main thread.
        DispatchQueue.global(qos: .utility).async { try? input.write(contentsOf: data) }
    }

    /// Bytes read so far; touched only by the handle's serial readability handler.
    private final class Buffer: @unchecked Sendable { var data = Data() }

    private static func readLines(_ handle: FileHandle, limit: Int, _ onLine: @escaping @MainActor (Data) -> Void) {
        let box = Buffer()
        handle.readabilityHandler = { h in
            var buffer = box.data
            defer { box.data = buffer }
            let chunk = h.availableData
            guard !chunk.isEmpty else { h.readabilityHandler = nil; return }
            buffer.append(chunk)
            var lines: [Data] = []
            while let nl = buffer.firstIndex(of: 0x0a) {
                lines.append(Data(buffer[buffer.startIndex..<nl]))
                buffer.removeSubrange(buffer.startIndex...nl)
            }
            // A runaway line without a newline: hand over what we have and drop the rest.
            if buffer.count > limit * 2 { lines.append(buffer); buffer = Data() }
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { lines.forEach(onLine) } }
        }
    }

    /// The child becomes its own responsible process for TCC, when this macOS has the call.
    private static func disclaim(_ attributes: inout posix_spawnattr_t?) {
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return }
        _ = unsafeBitCast(symbol, to: Disclaim.self)(&attributes, 1)
    }

    /// A small, predictable environment instead of tip's own.
    static func environment(directory: URL, id: String) -> [String] {
        let env = ProcessInfo.processInfo.environment
        var out = [
            "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TIP_PLUGIN_ID=\(id)",
            "TIP_PLUGIN_DIR=\(directory.path)",
            "TIP_VERSION=\(AppPaths.version)",
            "TIP_SOCKET=\(IPC.socketPath)",
        ]
        for key in ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR"] {
            if let value = env[key] { out.append("\(key)=\(value)") }
        }
        return out
    }
}
