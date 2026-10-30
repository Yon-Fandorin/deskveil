import Darwin
import Foundation

struct UpdateReadiness {
    var blocking = false
    var recording = false
    var transitioning = false
    var recovering = false
    var individualDisplays = false
    var lidBusy = false
    var stopping = false
    var waitingReason: String? {
        if blocking { return L10n.text("입력 차단 해제 후 적용") }
        if recording { return L10n.text("단축키 설정 완료 후 적용") }
        if transitioning { return L10n.text("화면 전환 완료 후 적용") }
        if recovering || individualDisplays { return L10n.text("화면 복원 완료 후 적용") }
        if lidBusy { return L10n.text("잠자기 설정 복구 후 적용") }
        if stopping { return L10n.text("앱 정리 완료 후 적용") }
        return nil
    }
}

/// A user-local rendezvous for updates and explicit privacy recovery. It accepts
/// no executable/file paths and never ends a blocking session. Recovery requires
/// a signed app client; the updater separately verifies all release payloads.
final class DeferredUpdateGate {
    static var directory: String { "/private/tmp/softlock-update-\(getuid())" }
    static func socketPath(pid: pid_t) -> String { directory + "/\(pid).sock" }
    private let queue = DispatchQueue(label: "dev.local.softlock.update-gate")
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private var clientSource: DispatchSourceRead?
    private var client: Int32 = -1 // queue-owned; all App-facing state is main-thread-owned
    private var recoveryClient: Int32 = -1
    private var recoveryGeneration: UInt64 = 0
    private var generation: UInt64 = 0
    private var mainGeneration: UInt64?
    private var lifecycle = UUID()
    private var listeningLifecycle: UUID?
    private var prepared = false
    private var committed = false
    private var clientData = Data()
    private(set) var version: String?
    private(set) var available = false
    var pending: Bool { version != nil }
    var onChange: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onCommit: (() -> Void)?
    var onRenew: (() -> Void)?
    var onRevealPrivacy: (() -> Bool)?
    private let commitLease: TimeInterval
    private let clock: () -> TimeInterval
    private let authorizeRecovery: (pid_t, uid_t) -> Bool

    init(commitLease: TimeInterval = 5,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         authorizeRecovery: @escaping (pid_t, uid_t) -> Bool = PrivacyRecoveryCommand.authorizedClient) {
        precondition(commitLease > 0 && commitLease <= 5)
        self.commitLease = commitLease; self.clock = clock
        self.authorizeRecovery = authorizeRecovery
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var value = sockaddr_un()
        value.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw LidError("Update socket path too long") }
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &value.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        return value
    }
    func start() throws {
        var info = stat()
        if lstat(Self.directory, &info) != 0 {
            guard errno == ENOENT else { throw LidError(L10n.text("업데이트 대기 경로를 확인하지 못했습니다.")) }
            if mkdir(Self.directory, 0o700) != 0, errno != EEXIST { throw LidError(L10n.text("업데이트 대기 경로를 만들지 못했습니다.")) }
        }
        guard lstat(Self.directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw LidError(L10n.text("업데이트 대기 경로를 확인하지 못했습니다.")) }
        let path = Self.socketPath(pid: getpid())
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw LidError(L10n.text("업데이트 대기 주소를 확인하지 못했습니다.")) }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw LidError(L10n.text("업데이트 대기 주소를 확인하지 못했습니다.")) }
            _ = fcntl(probe, F_SETFL, O_NONBLOCK)
            var address = try Self.address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            let stale = result != 0 && errno == ECONNREFUSED
            close(probe)
            var again = stat()
            guard stale, lstat(path, &again) == 0, again.st_dev == info.st_dev, again.st_ino == info.st_ino,
                  unlink(path) == 0 else { throw LidError(L10n.text("업데이트 대기 주소가 이미 사용 중입니다.")) }
        } else if errno != ENOENT { throw LidError(L10n.text("업데이트 대기 주소를 확인하지 못했습니다.")) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LidError(L10n.text("업데이트 대기를 시작하지 못했습니다.")) }
        var address = try Self.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 2) == 0 else {
            close(fd); unlink(path); throw LidError(L10n.text("업데이트 대기 주소를 열지 못했습니다."))
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let lifetime = UUID(); lifecycle = lifetime
        queue.sync { listener = fd; listeningLifecycle = lifetime }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptRequest(listener: fd, lifetime: lifetime) }
        self.source = source; source.resume(); available = true
    }
    private func acceptRequest(listener: Int32, lifetime: UUID) {
        guard self.listener == listener, listeningLifecycle == lifetime else { return }
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); return }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var noPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        var data = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !data.contains(10), data.count <= 512, ProcessInfo.processInfo.systemUptime < deadline {
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pollFD, 1, 100) >= 0 else { break }
            var bytes = [UInt8](repeating: 0, count: 512)
            let count = read(fd, &bytes, bytes.count)
            if count > 0 { data.append(contentsOf: bytes.prefix(count)) }
            else if count == 0 || (errno != EAGAIN && errno != EINTR) { break }
        }
        guard data.count <= 512, data.last == 10,
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { close(fd); return }
        if request == ["command": "reveal-privacy"] {
            acceptRecovery(fd: fd, uid: uid, lifetime: lifetime)
            return
        }
        guard client < 0, request["command"] == "defer", let version = request["version"],
              version.utf8.count <= 32,
              version.range(of: "\\A[0-9]+(?:\\.[0-9]+){0,3}\\z", options: .regularExpression) != nil else { close(fd); return }
        client = fd; generation += 1; prepared = false; committed = false; clientData = Data()
        let generation = generation
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.readClient(fd: fd, generation: generation) }
        clientSource = reader; reader.resume()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.available, self.lifecycle == lifetime else { return }
            self.mainGeneration = generation
            self.version = version
            self.send("waiting", reason: L10n.text("상태 확인 중"), generation: generation)
            self.onChange?()
        }
    }
    private func acceptRecovery(fd: Int32, uid: uid_t, lifetime: UUID) {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard recoveryClient < 0,
              getsockopt(fd, 0, 2, &pid, &size) == 0, size == MemoryLayout<pid_t>.size,
              pid > 1, authorizeRecovery(pid, uid) else { close(fd); return }
        recoveryClient = fd; recoveryGeneration &+= 1
        let generation = recoveryGeneration, expiresAt = clock() + 2
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let connected = self.queue.sync { () -> Bool in
                guard self.recoveryClient == fd, self.recoveryGeneration == generation else { return false }
                var byte: UInt8 = 0
                let count = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                return count < 0 && (errno == EAGAIN || errno == EINTR)
            }
            let allowed = self.available && self.lifecycle == lifetime && self.clock() <= expiresAt && connected
            let revealed = allowed && self.onRevealPrivacy?() == true
            self.queue.async {
                guard self.recoveryClient == fd, self.recoveryGeneration == generation else { return }
                if allowed, let data = try? JSONSerialization.data(withJSONObject:
                    ["state": revealed ? "revealed" : "not-active", "pid": getpid()]) {
                    let wire = data + Data([10])
                    _ = wire.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                }
                close(fd); self.recoveryClient = -1
            }
        }
    }
    private func dropClient(generation: UInt64) {
        guard self.generation == generation else { return }
        let hadCommitted = committed
        clientSource?.cancel(); clientSource = nil
        if client >= 0 { close(client); client = -1 }
        if !hadCommitted {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.mainGeneration == generation else { return }
                self.mainGeneration = nil; self.version = nil
                self.onChange?(); self.onDisconnect?()
            }
        }
    }
    private func readClient(fd: Int32, generation: UInt64) {
        guard client == fd, self.generation == generation else { return }
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = read(fd, &bytes, bytes.count)
        if count == 0 { dropClient(generation: generation); return }
        if count < 0 {
            if errno != EAGAIN && errno != EINTR { dropClient(generation: generation) }
            return
        }
        clientData.append(contentsOf: bytes.prefix(count))
        guard clientData.count <= 256 else { dropClient(generation: generation); return }
        while let newline = clientData.firstIndex(of: 10) {
            let line = clientData[..<newline]; clientData.removeSubrange(...newline)
            guard prepared, !committed,
                  let message = try? JSONSerialization.jsonObject(with: line) as? [String: String],
                  let command = message["command"], command == "renew" || command == "commit" else {
                dropClient(generation: generation); return
            }
            if command == "commit" { committed = true }
            let expiresAt = clock() + commitLease
            DispatchQueue.main.async { [weak self] in
                guard let self, self.mainGeneration == generation else { return }
                if command == "renew" { self.onRenew?() }
                else if self.clock() <= expiresAt { self.onCommit?() }
                else {
                    // The updater may already have abandoned its bounded exit
                    // wait. Never execute a stale queued termination afterward.
                    self.mainGeneration = nil; self.version = nil
                    self.queue.async { self.dropClient(generation: generation) }
                    self.onChange?(); self.onDisconnect?()
                }
            }
        }
    }
    func reportWaiting(_ reason: String) { send("waiting", reason: reason) }
    func finish(_ completion: @escaping (Bool) -> Void) { send("ready", completion: completion) }
    private func send(_ state: String, reason: String = "", generation expected: UInt64? = nil,
                      completion: ((Bool) -> Void)? = nil) {
        let expected = expected ?? mainGeneration
        queue.async { [weak self] in
            guard let self else { return }
            guard self.client >= 0, expected == self.generation else {
                DispatchQueue.main.async { completion?(false) }; return
            }
            var byte: UInt8 = 0
            let peek = recv(self.client, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            let alive = peek > 0 || (peek < 0 && (errno == EAGAIN || errno == EINTR))
            let data = try? JSONSerialization.data(withJSONObject: ["state": state, "reason": reason, "pid": getpid()])
            let wire = data.map { $0 + Data([10]) } ?? Data()
            let sent = alive && !wire.isEmpty && wire.withUnsafeBytes { write(self.client, $0.baseAddress, $0.count) } == wire.count
            if sent && state == "ready" { self.prepared = true }
            if !sent { self.dropClient(generation: self.generation) }
            DispatchQueue.main.async { completion?(sent) }
        }
    }
    func stop() {
        mainGeneration = nil; available = false; lifecycle = UUID()
        source?.cancel(); source = nil
        queue.sync {
            clientSource?.cancel(); clientSource = nil; listeningLifecycle = nil
            if listener >= 0 { close(listener); listener = -1; unlink(Self.socketPath(pid: getpid())) }
            if client >= 0 { close(client); client = -1 }
            if recoveryClient >= 0 { close(recoveryClient); recoveryClient = -1 }
            recoveryGeneration &+= 1
        }
        version = nil
    }
}
