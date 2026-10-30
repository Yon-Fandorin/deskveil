import Foundation

/// The app captures state on Main; disk I/O retains only the newest pending snapshot.
final class DiagnosticsWriter {
    private struct Snapshot {
        let data: Data
        let completion: ((Bool) -> Void)?
    }
    private let queue = DispatchQueue(label: "dev.local.softlock.diagnostics", qos: .utility)
    private let mutex = NSLock()
    private let writes = DispatchGroup()
    private let write: (Data) -> Bool
    private var pending: Snapshot?
    private var writing = false

    init(url: URL) {
        write = { (try? $0.write(to: url, options: .atomic)) != nil }
    }
    init(write: @escaping (Data) -> Bool) { self.write = write }

    func submit(_ data: Data, completion: ((Bool) -> Void)? = nil) {
        mutex.lock()
        pending = Snapshot(data: data, completion: completion)
        guard !writing else { mutex.unlock(); return }
        writing = true
        writes.enter()
        mutex.unlock()
        queue.async { self.drain() }
    }

    private func drain() {
        while true {
            mutex.lock()
            guard let snapshot = pending else {
                writing = false
                writes.leave()
                mutex.unlock()
                return
            }
            pending = nil
            mutex.unlock()
            let succeeded = write(snapshot.data)
            if let completion = snapshot.completion {
                DispatchQueue.main.async { completion(succeeded) }
            }
        }
    }

    @discardableResult func flush(timeout: TimeInterval = 1) -> Bool {
        writes.wait(timeout: .now() + timeout) == .success
    }
}
