import AppKit
import Darwin

/// A UI-free recovery client. Existing input/OS locks remain untouched; only the
/// running app can decide whether there is a privacy surface to dismiss.
enum PrivacyRecoveryCommand {
    static func authorizedClient(_ pid: pid_t, _ uid: uid_t) -> Bool {
        guard uid == getuid(), let own = Bundle.main.executableURL,
              let requirement = try? lidClientRequirement(own.path) else { return false }
        return lidPeerIsAllowed(pid, uid: uid, configuration: ["uid": uid, "clientRequirement": requirement])
    }

    static func run() throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        guard let identifier = Bundle.main.bundleIdentifier else { throw LidError(L10n.text("앱 식별자를 확인하지 못했습니다.")) }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter {
            $0.processIdentifier != getpid() && !$0.isTerminated && $0.isFinishedLaunching &&
                RelaunchHandoff.Peer.read($0.processIdentifier)?.uid == getuid() &&
                authorizedClient($0.processIdentifier, getuid())
        }
        // A cover guardian can register the same bundle in Launch Services.
        // Only a live, authenticated control endpoint belongs to the main app.
        // Probing sends no command and therefore cannot reveal any surface.
        let candidates = applications.filter {
            (try? withConnection(pid: $0.processIdentifier, authorizePeer: authorizedClient, until: deadline) { _, _ in true }) == true
        }
        guard candidates.count == 1 else {
            throw LidError(L10n.text("같은 사용자로 실행 중인 DeskVeil 하나를 확인해야 복구할 수 있습니다."))
        }
        return try request(pid: candidates[0].processIdentifier, deadline: deadline)
    }

    static func request(pid: pid_t, authorizePeer: (pid_t, uid_t) -> Bool = authorizedClient,
                        deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 3) throws -> Bool {
        try withConnection(pid: pid, authorizePeer: authorizePeer, until: deadline) { fd, deadline in
            let wire = Data("{\"command\":\"reveal-privacy\"}\n".utf8)
            var sent = 0
            while sent < wire.count {
                try wait(fd, for: Int16(POLLOUT), until: deadline)
                let count = wire.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: sent), $0.count - sent) }
                if count > 0 { sent += count }
                else if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                else { throw LidError(L10n.text("화면 복구 요청을 보내지 못했습니다.")) }
            }
            var data = Data()
            while !data.contains(10) && data.count < 512 {
                try wait(fd, for: Int16(POLLIN), until: deadline)
                var bytes = [UInt8](repeating: 0, count: 512)
                let count = read(fd, &bytes, bytes.count)
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0 else { throw LidError(L10n.text("복구 응답을 받지 못했습니다. 기존 긴급 해제를 사용해주세요.")) }
                data.append(contentsOf: bytes.prefix(count))
            }
            guard data.count <= 512, data.last == 10,
                  let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  reply["pid"] as? Int32 == pid, let state = reply["state"] as? String,
                  state == "revealed" || state == "not-active" else { throw LidError(L10n.text("앱의 복구 응답이 올바르지 않습니다.")) }
            return state == "revealed"
        }
    }

    private static func wait(_ fd: Int32, for event: Int16, until deadline: TimeInterval) throws {
        while ProcessInfo.processInfo.systemUptime < deadline {
            let milliseconds = Int32(max(1, (deadline - ProcessInfo.processInfo.systemUptime) * 1000))
            var item = pollfd(fd: fd, events: event, revents: 0)
            let result = poll(&item, 1, milliseconds)
            if result > 0 { return }
            if result < 0 && errno != EINTR { break }
        }
        throw LidError(L10n.text("복구 응답 시간이 초과됐습니다. 기존 긴급 해제를 사용해주세요."))
    }

    private static func withConnection<T>(pid: pid_t, authorizePeer: (pid_t, uid_t) -> Bool, until deadline: TimeInterval,
                                          perform: (Int32, TimeInterval) throws -> T) throws -> T {
        guard pid > 1 else { throw LidError(L10n.text("복구 대상 프로세스가 올바르지 않습니다.")) }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw LidError(L10n.text("복구 연결 시간이 초과됐습니다.")) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LidError(L10n.text("복구 연결을 만들지 못했습니다.")) }
        defer { close(fd) }
        var noPipe: Int32 = 1
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw LidError(L10n.text("복구 연결의 시간 제한을 설정하지 못했습니다."))
        }
        var address = try DeferredUpdateGate.address(DeferredUpdateGate.socketPath(pid: pid))
        let connected = withUnsafePointer(to: &address, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        })
        if connected != 0 {
            guard errno == EINPROGRESS else { throw LidError(L10n.text("실행 중인 앱의 복구 경로에 연결하지 못했습니다.")) }
            try wait(fd, for: Int16(POLLOUT), until: deadline)
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw LidError(L10n.text("실행 중인 앱의 복구 경로에 연결하지 못했습니다."))
            }
        }
        var uid: uid_t = 0, gid: gid_t = 0, peerPID: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
              getsockopt(fd, 0, 2, &peerPID, &size) == 0, size == MemoryLayout<pid_t>.size,
              peerPID == pid, authorizePeer(peerPID, uid) else { throw LidError(L10n.text("복구 대상 앱의 신원을 확인하지 못했습니다.")) }
        return try perform(fd, deadline)
    }
}
