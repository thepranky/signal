import Foundation

/// Watches a directory for entry changes (files added, replaced, or removed)
/// and invokes `onChange` on a background queue. The Signal hook writes state
/// files via atomic rename and removes them on session end, both of which are
/// directory-level changes this picks up.
final class DirectoryWatcher {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private var fileDescriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        stop()
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)

        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.global(qos: .utility))

        src.setEventHandler { [weak self] in self?.onChange() }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }
        source = src
        src.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}
