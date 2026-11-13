import Foundation

/// Calls `onChange` (debounced, on the main actor) when one of `urls` changes, however it is
/// saved: an editor that replaces the file shows up on its folder, an in-place write
/// (VS Code, scripts) only on the file itself. Each folder is watched once however many of the
/// files live in it, and one save fires one callback. The files are watched again after every
/// change, because a replaced file is a new inode.
final class FileWatcher {
    let urls: [URL]
    private let onChange: () -> Void
    private var folders: [DispatchSourceFileSystemObject] = []
    private var files: [DispatchSourceFileSystemObject] = []
    private var pending: Task<Void, Never>?

    convenience init(url: URL, onChange: @escaping () -> Void) {
        self.init(urls: [url], onChange: onChange)
    }

    init(urls: [URL], onChange: @escaping () -> Void) {
        self.urls = urls
        self.onChange = onChange
        var seen = Set<String>()
        for dir in urls.map({ $0.deletingLastPathComponent().path }) where seen.insert(dir).inserted {
            if let s = source(dir, [.write, .rename, .delete]) { folders.append(s) }
        }
        watchFiles()
    }

    func stop() {
        pending?.cancel()
        (folders + files).forEach { $0.cancel() }
        folders = []
        files = []
    }

    private func watchFiles() {
        files.forEach { $0.cancel() }
        files = urls.compactMap { source($0.path, [.write, .extend, .rename, .delete]) }
    }

    private func source(_ path: String, _ mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        s.setEventHandler { [weak self] in self?.changed() }
        s.setCancelHandler { close(fd) }
        s.resume()
        return s
    }

    private func changed() {
        pending?.cancel()
        // On the main actor: the reload touches AppKit and the window manager.
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            watchFiles()
            onChange()
        }
    }
}
