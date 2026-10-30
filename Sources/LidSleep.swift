import AppKit
import Darwin
import Foundation

private final class LidConnection {
    private var fd: Int32 = -1
    private var buffer = Data()
    func closeConnection() { if fd >= 0 { close(fd) }; fd = -1; buffer = Data() }
    deinit { closeConnection() }
    func exchange(_ request: [String: Any]) throws -> [String: Any] {
        do {
            if fd < 0 {
                fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { throw LidError(L10n.text("전원 보조 도구에 연결하지 못했습니다.")) }
                _ = fcntl(fd, F_SETFL, O_NONBLOCK)
                var address = try lidSocketAddress(LidPaths.socket)
                let result = lidWithAddress(&address) { connect(fd, $0, $1) }
                if result != 0 {
                    guard errno == EINPROGRESS else { throw LidError(L10n.text("전원 보조 도구 연결을 기다리는 중입니다.")) }
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    guard poll(&descriptor, 1, 500) > 0 else { throw LidError(L10n.text("전원 보조 도구가 응답하지 않습니다.")) }
                    var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                        throw LidError(L10n.text("전원 보조 도구에 연결하지 못했습니다."))
                    }
                }
                var uid: uid_t = 1, gid: gid_t = 1
                guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else { throw LidError(L10n.text("전원 보조 도구의 신원을 확인하지 못했습니다.")) }
            }
            try lidWriteLine(fd, request)
            let deadline = lidTime() + 4
            while lidTime() < deadline {
                if let end = buffer.firstIndex(of: 10) {
                    let line = buffer[..<end]; buffer.removeSubrange(...end)
                    guard let value = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                          value["protocol"] as? Int == LidPaths.protocolVersion else { throw LidError(L10n.text("보조 도구를 업데이트해주세요.")) }
                    return value
                }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 100) >= 0 else { throw LidError(L10n.text("보조 도구 연결이 중단됐습니다.")) }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = read(fd, &bytes, bytes.count)
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0, buffer.count + count <= 8192 else { throw LidError(L10n.text("보조 도구 연결이 중단됐습니다.")) }
                buffer.append(contentsOf: bytes.prefix(count))
            }
            throw LidError(L10n.text("전원 보조 도구 응답이 지연되고 있습니다."))
        } catch { closeConnection(); throw error }
    }
}

/// Main-loop heartbeats own the requested scope. The transport never generates
/// its own heartbeats, so a frozen UI cannot keep privileged power control alive.
final class LidSleepController {
    private let queue = DispatchQueue(label: "dev.local.softlock.lid-client", qos: .utility)
    private let connection = LidConnection()
    private let installedOverride: (() -> Bool)?
    private let exchangeOverride: (([String: Any]) throws -> [String: Any])?
    private let contextOverride: (() -> [String: Any])?
    private var inFlight = false
    private var scopeNeedsRelease = false
    private var preparationNeedsRelease = false
    private let recoveryPending: () -> Bool
    private var lastExchange: TimeInterval = -.infinity
    private var activation: ((Result<Void, Error>) -> Void)?
    private var preparingSince: TimeInterval?
    private var installer: Process?
    private var previouslyActive = false
    private var sessionID = UUID().uuidString
    private let createdAt = lidTime()
    private lazy var installationIdentity = try? LidInstallationIdentity.current()
    private(set) var phase = "unavailable"
    private(set) var reason = ""
    private(set) var snapshot: [String: Any] = [:]
    private(set) var preparationDuration: TimeInterval?
    var onChange: (() -> Void)?
    var onPreparationUpdate: (() -> Void)?
    var onUnexpectedEnd: ((String, String) -> Void)?
    var preparing: Bool { preparingSince != nil }
    var busy: Bool { installer != nil || preparing }
    var active: Bool { phase == "active" && snapshot["session"] as? String == sessionID }
    var recovering: Bool { phase == "recovering" }
    var settled: Bool { !busy && !active && !recovering && !scopeNeedsRelease && !recoveryPending() }
    init(installed: (() -> Bool)? = nil, context: (() -> [String: Any])? = nil,
         exchange: (([String: Any]) throws -> [String: Any])? = nil,
         recoveryPending: @escaping () -> Bool = { FileManager.default.fileExists(atPath: LidPaths.receipt) }) {
        installedOverride = installed; exchangeOverride = exchange
        contextOverride = context
        self.recoveryPending = recoveryPending
    }
    var installed: Bool {
        if let installedOverride { return installedOverride() }
        guard let identity = installationIdentity,
              let configuration = try? lidJSON(LidPaths.configuration) else { return false }
        return identity.matches(configuration)
    }
    var needsSetup: Bool { !installed || (phase == "unavailable" && lidTime() - createdAt >= 5) }
    var setupTitle: String { installed ? L10n.text("보조 도구 다시 연결…") : (FileManager.default.fileExists(atPath: LidPaths.configuration) ? L10n.text("보조 도구 업데이트…") : L10n.text("보조 도구 설치…")) }
    var statusText: String {
        if installer != nil { return L10n.text("관리자 승인 · 설치 중") }
        if preparing { return L10n.text("차단 준비 중") }
        if scopeNeedsRelease && !active { return L10n.text("잠자기 설정 복구 확인 중") }
        if !installed { return FileManager.default.fileExists(atPath: LidPaths.configuration) ? L10n.text("보조 도구 업데이트 필요") : L10n.text("설정 전") }
        switch phase {
        case "active":
            let remaining = snapshot["remainingSeconds"] as? Double ?? -1
            return L10n.text("동작 중 · ") + (remaining < 0 ? L10n.text("무제한") : LidDuration.remainingText(remaining))
        case "recovering": return L10n.text("잠자기 설정 복구 중")
        case "idle": return L10n.text("준비됨")
        case "ended", "failed": return reasonText
        default: return L10n.text("보조 도구 연결 확인 중")
        }
    }
    var reasonText: String {
        switch reason {
        case "existing-power-policy": return L10n.text("다른 잠자기 방지 설정이 사용 중입니다.")
        case "power-required", "power-disconnected": return PowerRestriction.externalPowerRequired.message()
        case "battery-low": return PowerRestriction.batteryLow.message(
            reservePercent: BatteryReserve.percent(from: snapshot["batteryReservePercent"]) ?? BatteryReserve.stored())
        case "battery-unavailable": return PowerRestriction.batteryUnavailable.message()
        case "session-limit": return L10n.text("설정한 유지 시간이 끝났습니다.")
        case "unlocked", "scope-ended": return L10n.text("차단 해제로 종료됨")
        case "app-unresponsive", "app-disconnected": return L10n.text("앱 연결 중단으로 덮개 유지를 종료했습니다.")
        case "macOS-session-ended": return L10n.text("macOS 잠금·사용자 전환으로 종료됨")
        default: return reason.isEmpty ? L10n.text("전원 보조 도구를 확인해주세요.") : L10n.text("덮개 유지를 계속할 수 없습니다. 동작 기록에서 복구 상태를 확인해주세요.")
        }
    }

    func prepare(_ completion: @escaping (Result<Void, Error>) -> Void) {
        guard installed else { completion(.failure(LidError(L10n.text("‘접근 권한’에서 ‘%@’를 눌러주세요.", String(describing: setupTitle))))); return }
        guard !busy else { return }
        preparationNeedsRelease = scopeNeedsRelease
        sessionID = UUID().uuidString
        scopeNeedsRelease = true
        preparationDuration = nil
        lastExchange = -.infinity
        preparingSince = lidTime(); activation = completion; onChange?()
    }

    func update(requested: Bool, locked: Bool, ready: Bool, awake: Bool, durationSeconds: Int,
                allowBattery: Bool = false, reservePercent: Int = BatteryReserve.defaultPercent) {
        guard installer == nil, installed, !inFlight, lidTime() - lastExchange >= 0.25 else { return }
        if let began = preparingSince, lidTime() - began > 8 { finishPreparation(.failure(LidError(L10n.text("덮개 모드 준비 시간이 초과됐습니다.")))) }
        let releasingForPreparation = preparing && preparationNeedsRelease
        let message = (contextOverride?() ?? Self.currentContext()).merging([
            "protocol": LidPaths.protocolVersion, "requested": !releasingForPreparation && (requested || preparing),
            "allowBattery": allowBattery,
            "batteryReservePercent": reservePercent,
            "durationSeconds": durationSeconds, "session": sessionID,
            "preparing": preparing && !releasingForPreparation, "locked": locked, "ready": ready, "awake": awake]) { _, current in current }
        inFlight = true; lastExchange = lidTime()
        if message["requested"] as? Bool == true { scopeNeedsRelease = true }
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result {
                if let exchange = self.exchangeOverride { return try exchange(message) }
                return try self.connection.exchange(message)
            }
            DispatchQueue.main.async {
                let oldStatus = self.statusText
                self.inFlight = false
                let currentSession = message["session"] as? String == self.sessionID
                switch result {
                case .success(let state):
                    self.snapshot = state; self.phase = state["phase"] as? String ?? "unavailable"
                    self.reason = state["reason"] as? String ?? ""
                    if currentSession, message["requested"] as? Bool == false,
                       ["idle", "ended", "failed"].contains(self.phase) {
                        self.scopeNeedsRelease = false; self.preparationNeedsRelease = false
                        if self.preparing { self.lastExchange = -.infinity }
                    }
                    if self.preparing && currentSession && !releasingForPreparation {
                        if self.active { self.finishPreparation(.success(())) }
                        else if ["failed", "ended"].contains(self.phase) {
                            self.finishPreparation(.failure(LidError(self.reasonText)))
                        }
                    }
                case .failure(let error):
                    self.phase = "unavailable"; self.reason = "connection-ended"
                    if self.preparing && currentSession { self.finishPreparation(.failure(error)) }
                }
                if self.previouslyActive && !self.active && requested { self.onUnexpectedEnd?(self.reason, self.reasonText) }
                self.previouslyActive = self.active
                if oldStatus != self.statusText { self.onChange?() }
                // A heartbeat already in flight must not defer a new lock until
                // the next one-second tick. Ask the owner for fresh scope now.
                if self.preparing && (message["preparing"] as? Bool != true || message["session"] as? String != self.sessionID) {
                    self.onPreparationUpdate?()
                }
            }
        }
    }

    private static func currentContext() -> [String: Any] {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        var displayCount: UInt32 = 0
        let displayQuery = CGGetOnlineDisplayList(0, nil, &displayCount)
        return [
            "sessionReady": session?[kCGSessionOnConsoleKey as String] as? Bool == true && session?["CGSSessionScreenIsLocked"] as? Bool != true,
            "displayCount": displayCount, "displayQuery": displayQuery.rawValue,
            "hidIdleSeconds": CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: UInt32.max)!),
            "sessionIdleSeconds": CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)]
    }

    private func finishPreparation(_ result: Result<Void, Error>) {
        if let began = preparingSince { preparationDuration = lidTime() - began }
        let reply = activation; activation = nil; preparingSince = nil
        reply?(result)
    }

    func cancelPreparation() {
        activation = nil; preparingSince = nil
    }

    func disconnect() {
        cancelPreparation()
        queue.async { [self] in connection.closeConnection() }
    }

    func install(remove: Bool = false, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !busy, !active, !recovering, !scopeNeedsRelease, let executable = Bundle.main.executableURL else { return }
        let operation = remove ? "--lid-uninstall" : "--lid-install"
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = [executable.path, operation, "--app-pid", String(getpid())].map(quote).joined(separator: " ")
        let literal = "\"" + command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \(literal) with administrator privileges"]
        process.standardOutput = output; process.standardError = error
        installer = process; onChange?()
        process.terminationHandler = { [weak self] process in
            let diagnostic = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                guard let self else { return }
                self.installer = nil; self.phase = "unavailable"; self.reason = ""
                self.queue.async { self.connection.closeConnection() }
                if process.terminationStatus == 0 { completion(.success(())) }
                else { completion(.failure(LidError(diagnostic.contains("-128") ? L10n.text("관리자 승인을 취소했습니다.") : L10n.text("보조 도구 설정을 마치지 못했습니다. %@", String(describing: diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)))))) }
                self.onChange?()
            }
        }
        do { try process.run() }
        catch { installer = nil; completion(.failure(error)); onChange?() }
    }

    func revealLog() { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: LidPaths.log)]) }
}
