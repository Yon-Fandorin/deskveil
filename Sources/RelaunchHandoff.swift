import Darwin
import Foundation

/// A restart is admitted only after this exact predecessor has stopped. Launch
/// Services returning a process is not evidence that its startup accepted us.
final class RelaunchHandoff {
    struct Peer: Codable, Equatable {
        let pid: pid_t
        let uid: uid_t
        let seconds: UInt64
        let microseconds: UInt64
        let executable: String

        static func read(_ pid: pid_t) -> Self? {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) else { return nil }
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
            return Self(pid: pid, uid: info.pbi_uid, seconds: info.pbi_start_tvsec,
                        microseconds: info.pbi_start_tvusec,
                        executable: URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path)
        }
    }

    struct Context {
        let root: URL
        let own: Peer
        let requirement: String
        let lookup: (pid_t) -> Peer?
        let alive: (pid_t) -> Bool
        let authorized: (pid_t, uid_t, String) -> Bool

        static func current() throws -> Self {
            guard let own = Peer.read(getpid()), own.uid == getuid() else { throw failure() }
            return Self(root: URL(fileURLWithPath: "/private/tmp"), own: own,
                requirement: try lidClientRequirement(own.executable), lookup: Peer.read,
                alive: { kill($0, 0) == 0 || errno == EPERM },
                authorized: { lidPeerIsAllowed($0, uid: $1, configuration: ["uid": $1, "clientRequirement": $2]) })
        }
    }

    private struct Record: Codable, Equatable { let parent: Peer; let requirement: String }
    enum PredecessorState { case waiting, released, cancelled }
    let token: String
    private let context: Context
    private let record: Record
    private let directory: URL
    private let inode: ino_t

    private init(token: String, context: Context, record: Record, inode: ino_t) {
        self.token = token; self.context = context; self.record = record; self.inode = inode
        directory = Self.directory(token, context)
    }

    static func create(context: Context? = nil) throws -> RelaunchHandoff {
        let context = try context ?? Context.current()
        let token = UUID().uuidString, directory = directory(token, context)
        guard mkdir(directory.path, 0o700) == 0 else { throw failure() }
        guard let fd = openDirectory(directory, uid: context.own.uid) else { _ = rmdir(directory.path); throw failure() }
        defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0 else { _ = rmdir(directory.path); throw failure() }
        let handoff = RelaunchHandoff(token: token, context: context,
            record: Record(parent: context.own, requirement: context.requirement), inode: info.st_ino)
        do { try write(handoff.record, name: "record.json", at: fd) }
        catch { handoff.cancel(); throw error }
        return handoff
    }

    static func accept(_ token: String, context: Context? = nil) throws -> RelaunchHandoff {
        guard UUID(uuidString: token)?.uuidString == token else { throw failure() }
        let context = try context ?? Context.current()
        let directory = directory(token, context)
        guard let fd = openDirectory(directory, uid: context.own.uid) else { throw failure() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              let record: Record = read("record.json", at: fd, uid: context.own.uid),
              record.requirement == context.requirement,
              record.parent.pid != context.own.pid,
              record.parent.uid == context.own.uid,
              record.parent.executable == context.own.executable,
              context.lookup(record.parent.pid) == record.parent,
              context.authorized(record.parent.pid, record.parent.uid, record.requirement) else { throw failure() }
        try write(context.own, name: "ready.json", at: fd)
        return RelaunchHandoff(token: token, context: context, record: record, inode: info.st_ino)
    }

    func ready(for childPID: pid_t) -> Bool {
        guard let fd = descriptor() else { return false }
        defer { close(fd) }
        guard let peer: Peer = Self.read("ready.json", at: fd, uid: context.own.uid),
              peer.pid == childPID, peer.pid != context.own.pid,
              peer.uid == context.own.uid, peer.executable == context.own.executable,
              context.lookup(childPID) == peer else { return false }
        return context.authorized(childPID, peer.uid, record.requirement)
    }

    func predecessorState() -> PredecessorState {
        guard let fd = descriptor() else { return .cancelled }
        defer { close(fd) }
        guard let stored: Record = Self.read("record.json", at: fd, uid: context.own.uid), stored == record else { return .cancelled }
        if !context.alive(record.parent.pid) { return .released }
        if let current = context.lookup(record.parent.pid) {
            // PID reuse is not a still-running predecessor. The usual singleton
            // check still runs before any hooks are started in the replacement.
            if current.seconds != record.parent.seconds || current.microseconds != record.parent.microseconds { return .released }
            return current == record.parent ? .waiting : .cancelled
        }
        return .waiting // A transient inspection failure never authorizes startup.
    }

    func cancel() {
        guard let fd = descriptor() else { return }
        _ = unlinkat(fd, "ready.json", 0); _ = unlinkat(fd, "record.json", 0)
        close(fd)
        _ = rmdir(directory.path)
    }

    private func descriptor() -> Int32? {
        guard let fd = Self.openDirectory(directory, uid: context.own.uid) else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_ino == inode else { close(fd); return nil }
        return fd
    }

    private static func directory(_ token: String, _ context: Context) -> URL {
        context.root.appendingPathComponent("softlock-relaunch-\(context.own.uid)-\(token)", isDirectory: true)
    }

    private static func openDirectory(_ url: URL, uid: uid_t) -> Int32? {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == uid, info.st_mode & 0o7777 == 0o700 else { close(fd); return nil }
        return fd
    }

    private static func write<T: Encodable>(_ value: T, name: String, at directory: Int32) throws {
        let data = try JSONEncoder().encode(value)
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard count == data.count else { _ = unlinkat(directory, name, 0); throw failure() }
    }

    private static func read<T: Decodable>(_ name: String, at directory: Int32, uid: uid_t) -> T? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == uid, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o7777 == 0o600, info.st_nlink == 1, info.st_size > 0, info.st_size <= 16_384 else { return nil }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count == data.count else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func failure() -> LidError { LidError(L10n.text("다시 시작할 앱의 준비 상태를 확인하지 못했습니다.")) }
}
