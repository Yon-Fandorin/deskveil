import CoreGraphics
import Darwin
import Foundation

private var lidServiceStopping: sig_atomic_t = 0

struct LidServiceFiles {
    let simulation: String?
    var socket: String { simulation.map { $0 + "/control.sock" } ?? LidPaths.socket }
    var log: String { simulation.map { $0 + "/session.jsonl" } ?? LidPaths.log }
    var receipt: String { simulation.map { $0 + "/recovery.json" } ?? LidPaths.receipt }
    var lock: String { simulation.map { $0 + "/lease.lock" } ?? LidPaths.lock }
    var state: String { simulation.map { $0 + "/state.json" } ?? LidPaths.state }
}

struct SimulatedLidPower: LidPowerBackend {
    let directory: String
    func disabled() throws -> Bool { try lidJSON(directory + "/power.json")["disabled"] as? Bool == true }
    func configuredDisabled() throws -> Bool { try disabled() }
    func setDisabled(_ value: Bool) throws {
        guard geteuid() != 0 else { throw LidError("Simulation must not run as root") }
        let faults = (try? lidJSON(directory + "/faults.json")) ?? [:]
        if value && faults["delayedEnable"] as? Bool == true {
            // A real in-flight command in the supervisor group, with a fake power file.
            let program = "import json,sys,time;from pathlib import Path;time.sleep(1.2);p=Path(sys.argv[1]);t=p.with_suffix('.late');t.write_text(json.dumps({'disabled':True}));t.replace(p)"
            _ = try LidCommand.run(["/usr/bin/python3", "-I", "-c", program, directory + "/power.json"], onLaunch: { pid in
                try? lidWriteJSON(["pid": pid], directory + "/inflight.json")
            })
        } else { try lidWriteJSON(["disabled": value], directory + "/power.json") }
        if value && faults["failAfterEnable"] as? Bool == true { throw LidError("Simulated partial application") }
    }
}

private func lidRestore(_ power: LidPowerBackend, files: LidServiceFiles, journal: LidJournal,
                        reason: String? = nil) {
    var retries = 0
    var lastError = ""
    while true {
        do {
            try autoreleasepool {
                try power.setDisabled(false)
                guard try !power.disabled() && !power.configuredDisabled() else { throw LidError("Restore not confirmed") }
                if FileManager.default.fileExists(atPath: files.receipt) { try FileManager.default.removeItem(atPath: files.receipt) }
                try? lidWriteJSON(["phase": "idle", "at": ISO8601DateFormatter().string(from: Date())], files.state)
            }
            // Recovery and every retry take priority over diagnostics. Preserve
            // its cause only after power and the durable receipt are restored.
            if retries > 0 { journal.emit("restore-retry", ["error": lastError, "retries": retries]) }
            journal.emit("restored", reason.map { ["reason": $0] } ?? [:])
            return
        } catch {
            retries += 1
            lastError = error.localizedDescription
            usleep(250_000)
        }
    }
}

private func lidSendCommand(_ handle: FileHandle, _ command: String) throws {
    let bytes = Array((command + "\n").utf8)
    let count = bytes.withUnsafeBytes { write(handle.fileDescriptor, $0.baseAddress, $0.count) }
    guard count == bytes.count || (count < 0 && errno == EAGAIN) else { throw LidError("Recovery watchdog disconnected") }
}

private func lidReadLines(_ fd: Int32, buffer: inout Data) throws -> [String] {
    var bytes = [UInt8](repeating: 0, count: 4096)
    let count = read(fd, &bytes, bytes.count)
    if count == 0 { throw LidError("Connection closed") }
    if count < 0 {
        if errno == EAGAIN || errno == EINTR { return [] }
        throw LidError("Connection read failed")
    }
    buffer.append(contentsOf: bytes.prefix(count))
    guard buffer.count <= 8192 else { throw LidError("Request too large") }
    var lines: [String] = []
    while let index = buffer.firstIndex(of: 10) {
        lines.append(String(decoding: buffer[..<index], as: UTF8.self))
        buffer.removeSubrange(...index)
    }
    return lines
}

func runLidWatchdog(files: LidServiceFiles, owner: pid_t, lease: TimeInterval) -> Never {
    guard owner > 1, getppid() == owner, getpgid(owner) == owner else { exit(2) }
    var ownerPath = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(owner, &ownerPath, UInt32(ownerPath.count)) > 0,
          let own = Bundle.main.executableURL,
          URL(fileURLWithPath: String(cString: ownerPath)).resolvingSymlinksInPath().path ==
            own.resolvingSymlinksInPath().path else { exit(2) }
    if getpgrp() != getpid() { guard setsid() >= 0 else { exit(2) } }
    signal(SIGPIPE, SIG_IGN)
    signal(SIGTERM) { _ in lidServiceStopping = 1 }
    let power: LidPowerBackend = files.simulation != nil ? SimulatedLidPower(directory: files.simulation!) : NativeLidPower()
    let journal = LidJournal(files.log)
    _ = fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK)
    var buffer = Data()
    var armed = false
    var lastHeartbeat = lidTime()
    print("ready"); fflush(stdout)
    var cleanStop = false
    while lidServiceStopping == 0 && lidTime() - lastHeartbeat < lease {
        var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        _ = poll(&input, 1, Int32(min(1, lease / 4) * 1000))
        do {
            for command in try lidReadLines(STDIN_FILENO, buffer: &buffer) {
                switch command {
                case "ping": lastHeartbeat = lidTime()
                case "arm": armed = true; print("armed"); fflush(stdout)
                case "release":
                    if armed { lidRestore(power, files: files, journal: journal); armed = false }
                    print("released"); fflush(stdout)
                    lastHeartbeat = lidTime()
                case "stop": cleanStop = true
                default: throw LidError("Invalid watchdog command")
                }
            }
        } catch { break }
        if cleanStop { break }
    }
    if !cleanStop {
        // This child is outside the group. No pending mutation may survive it.
        _ = killpg(owner, SIGKILL)
    }
    if armed {
        lidRestore(power, files: files, journal: journal,
                   reason: cleanStop ? "service-stopped" : "service-unresponsive")
    }
    exit(0)
}

/// A fixed power capability. The socket accepts state/heartbeat only, never
/// executable names, paths, shell text, or arbitrary privileged operations.
func runLidService(files: LidServiceFiles, lease: TimeInterval = LidPaths.lease) -> Never {
    signal(SIGPIPE, SIG_IGN)
    signal(SIGTERM) { _ in lidServiceStopping = 1 }
    signal(SIGINT) { _ in lidServiceStopping = 1 }
    if getpgrp() != getpid() { guard setsid() >= 0 else { exit(2) } }
    let simulation = files.simulation != nil
    guard simulation ? geteuid() != 0 : geteuid() == 0 else { exit(2) }
    if let directory = files.simulation {
        var info = stat()
        guard directory.hasPrefix("/private/tmp/softlock-lid-service-"), lstat(directory, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { exit(2) }
    }
    let journal = LidJournal(files.log)
    let power: LidPowerBackend = files.simulation != nil ? SimulatedLidPower(directory: files.simulation!) : NativeLidPower()
    var ownsRecovery = false
    do {
        let configuration = simulation ? ["uid": getuid()] : try lidJSON(LidPaths.configuration)
        guard let uid = configuration["uid"] as? UInt32 else { throw LidError("Service configuration unavailable") }
        let lock = open(files.lock, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw LidError("Recovery lock unavailable") }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_uid == geteuid(),
              (lockInfo.st_mode & S_IFMT) == S_IFREG, flock(lock, LOCK_EX) == 0 else {
            throw LidError("Invalid recovery lock")
        }
        // launchd restarts recover any receipt left by a reboot or both processes
        // being killed. No receipt means that somebody else's policy is untouched.
        if FileManager.default.fileExists(atPath: files.receipt) {
            guard try lidJSON(files.receipt)["baselineDisabled"] as? Bool == false else { throw LidError("Invalid recovery receipt") }
            ownsRecovery = true
            lidRestore(power, files: files, journal: journal, reason: "previous-session")
            ownsRecovery = false
        }
        let watchdog = Process()
        let commands = Pipe(), replies = Pipe()
        watchdog.executableURL = Bundle.main.executableURL
        var arguments = ["--lid-watchdog", "--owner", String(getpid()), "--lease", String(lease)]
        if let simulation = files.simulation { arguments += ["--simulation", simulation] }
        watchdog.arguments = arguments
        watchdog.standardInput = commands
        watchdog.standardOutput = replies
        // An inherited duplicate keeps the SAME flock description alive after
        // supervisor death. This internal mode never writes diagnostics to stderr.
        watchdog.standardError = FileHandle(fileDescriptor: lock, closeOnDealloc: false)
        try watchdog.run()
        commands.fileHandleForReading.closeFile(); replies.fileHandleForWriting.closeFile()
        _ = fcntl(commands.fileHandleForWriting.fileDescriptor, F_SETFL, O_NONBLOCK)
        _ = fcntl(replies.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
        var watchdogBuffer = Data()
        func awaitReply(_ expected: String, timeout: TimeInterval = 2) throws {
            let deadline = lidTime() + timeout
            while lidTime() < deadline {
                if try lidReadLines(replies.fileHandleForReading.fileDescriptor, buffer: &watchdogBuffer).contains(expected) { return }
                guard watchdog.isRunning else { throw LidError("Recovery watchdog exited") }
                usleep(10_000)
            }
            throw LidError("Recovery watchdog not ready")
        }
        try awaitReply("ready")
        journal.emit("ready", ["watchdogPID": watchdog.processIdentifier])
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw LidError("Cannot create power service") }
        if !simulation {
            let directory = (files.socket as NSString).deletingLastPathComponent
            try lidEnsureRootDirectory(directory, mode: 0o755)
        }
        _ = unlink(files.socket)
        var address = try lidSocketAddress(files.socket)
        guard lidWithAddress(&address, { bind(listener, $0, $1) }) == 0,
              chmod(files.socket, 0o600) == 0, (simulation || chown(files.socket, uid, 0) == 0),
              listen(listener, 4) == 0 else { throw LidError("Cannot open power service socket") }
        _ = fcntl(listener, F_SETFL, O_NONBLOCK)
        var client: Int32 = -1
        var clientPID: pid_t = 0
        var clientBuffer = Data()
        var lastHeartbeat: TimeInterval = 0
        var requested: [String: Any] = [:]
        var phase = "idle"
        var reason = ""
        var started: TimeInterval = 0
        var sessionLimit: TimeInterval = 0
        var sessionAllowsBattery = false
        var sessionReservePercent = BatteryReserve.defaultPercent
        var startedAt = ""
        var activeSession = ""
        var canStartAgain = false
        var lastSample: TimeInterval = 0
        var previousTick = lidTime()
        var lastPublished: TimeInterval = 0
        var publishedPhase = ""
        var powerSource = PowerSourceState(acPower: false)
        func release(_ cause: String) throws {
            if phase == "active" {
                phase = "recovering"; reason = cause
                try lidSendCommand(commands.fileHandleForWriting, "release")
                journal.emit("stopping", ["reason": cause])
            }
        }
        func status() -> [String: Any] {
            ["protocol": LidPaths.protocolVersion, "phase": phase, "reason": reason, "session": activeSession, "startedAt": startedAt,
             "limitSeconds": sessionLimit,
             "allowBattery": sessionAllowsBattery,
             "batteryReservePercent": phase == "failed"
                ? (BatteryReserve.percent(from: requested["batteryReservePercent"]) ?? sessionReservePercent) : sessionReservePercent,
             "acPower": powerSource.acPower,
             "batteryPercent": powerSource.batteryPercent.map { $0 as Any } ?? NSNull(),
             "remainingSeconds": sessionLimit > 0 ? max(0, ceil(sessionLimit - (lidTime() - started))) : -1,
             "sleepDisabled": (try? power.disabled()) ?? false,
             "lidClosed": lidRootProperties()["AppleClamshellState"] ?? false,
             "at": ISO8601DateFormatter().string(from: Date())]
        }
        defer {
            if client >= 0 { close(client) }
            close(listener); _ = unlink(files.socket)
        }
        while lidServiceStopping == 0 {
            try autoreleasepool {
                var responseNeeded = false
                let now = lidTime()
                if now - previousTick > 4 { journal.emit("observation-gap", ["seconds": now - previousTick]) }
                previousTick = now
                if !watchdog.isRunning {
                    if phase == "active" || phase == "recovering" {
                        lidRestore(power, files: files, journal: journal, reason: "watchdog-exited")
                    }
                    throw LidError("Recovery watchdog exited")
                }
                try lidSendCommand(commands.fileHandleForWriting, "ping")
                for reply in try lidReadLines(replies.fileHandleForReading.fileDescriptor, buffer: &watchdogBuffer) {
                    if reply == "released" {
                        phase = reason == "unlocked" || canStartAgain ? "idle" : "ended"
                        ownsRecovery = false
                    }
                }
                let incoming = accept(listener, nil, nil)
                if incoming >= 0 {
                    var peerUID: uid_t = 0, peerGID: gid_t = 0, peerPID: pid_t = 0
                    var length = socklen_t(MemoryLayout<pid_t>.size)
                    let authorized = getpeereid(incoming, &peerUID, &peerGID) == 0 && peerUID == uid &&
                        getsockopt(incoming, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &length) == 0 &&
                        (simulation || lidPeerIsAllowed(peerPID, uid: peerUID, configuration: configuration))
                    if client < 0 && authorized {
                        client = incoming; clientPID = peerPID; clientBuffer = Data(); requested = [:]
                        lastHeartbeat = now
                        _ = fcntl(client, F_SETFL, O_NONBLOCK)
                    } else { close(incoming) }
                }
                if client >= 0 {
                    do {
                        for line in try lidReadLines(client, buffer: &clientBuffer) {
                            guard let data = line.data(using: .utf8),
                                  let message = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  message["protocol"] as? Int == LidPaths.protocolVersion,
                                  let batteryOption = message["allowBattery"] as? NSNumber,
                                  CFGetTypeID(batteryOption) == CFBooleanGetTypeID(),
                                  BatteryReserve.percent(from: message["batteryReservePercent"]) != nil,
                                  LidDuration.seconds(from: message["durationSeconds"], simulation: simulation) != nil,
                                  let sessionID = message["session"] as? String,
                                  !sessionID.isEmpty, sessionID.count <= 64 else { throw LidError("Invalid power request") }
                            requested = message; lastHeartbeat = now
                            if message["requested"] as? Bool != true || sessionID != activeSession { canStartAgain = true }
                            if message["requested"] as? Bool != true { try release("unlocked") }
                            responseNeeded = true
                        }
                    } catch {
                        close(client); client = -1; requested = [:]
                        try release("app-disconnected")
                    }
                }
                let wantsPower = requested["requested"] as? Bool == true
                let preparing = requested["preparing"] as? Bool == true
                let scope = requested["ready"] as? Bool == true &&
                    (preparing || (requested["locked"] as? Bool == true && requested["awake"] as? Bool == true))
                // A system daemon has no GUI login session. The authenticated app
                // reports its own lock state; independently verify the console UID.
                let checkingScope = phase == "active" || wantsPower
                let macReady = simulation ? requested["sessionReady"] as? Bool != false :
                    (!checkingScope || (lidConsoleUserIs(uid) && requested["sessionReady"] as? Bool == true))
                if checkingScope {
                    if let directory = files.simulation {
                        let source = try lidJSON(directory + "/source.json")
                        powerSource = PowerSourceState(acPower: source["acPower"] as? Bool == true,
                                                       batteryPercent: source["batteryPercent"] as? Int)
                    } else { powerSource = NativePowerSource.current() }
                }
                let allowBattery = phase == "active" ? sessionAllowsBattery : requested["allowBattery"] as? Bool == true
                let reservePercent = phase == "active" ? sessionReservePercent :
                    (BatteryReserve.percent(from: requested["batteryReservePercent"]) ?? BatteryReserve.defaultPercent)
                let restriction = powerSource.restriction(allowBattery: allowBattery, reservePercent: reservePercent)
                let live = client >= 0 && kill(clientPID, 0) == 0 && now - lastHeartbeat < lease
                if phase == "active" {
                    if !live { try release("app-unresponsive") }
                    else if requested["session"] as? String != activeSession { try release("session-changed") }
                    else if !wantsPower { try release("scope-ended") }
                    else if let restriction { try release(restriction == .externalPowerRequired ? "power-disconnected" : restriction.rawValue) }
                    else if !scope { try release("scope-ended") }
                    else if !macReady { try release("macOS-session-ended") }
                    else if sessionLimit > 0 && now - started >= sessionLimit { try release("session-limit") }
                    else if preparing && now - started >= 5 { try release("start-not-confirmed") }
                    else if try !power.disabled() { try release("power-policy-changed") }
                } else if (phase == "idle" || (phase == "ended" && canStartAgain)) && wantsPower && live {
                    if !scope || restriction != nil || !macReady {
                        phase = "failed"; reason = restriction?.rawValue ?? "session-not-ready"
                        journal.emit("refused", ["reason": reason])
                    } else if try power.disabled() || power.configuredDisabled() {
                        phase = "failed"; reason = "existing-power-policy"
                        journal.emit("refused", ["reason": reason])
                    } else {
                        // A durable receipt exists BEFORE any possible mutation. A daemon
                        // restart/boot recovers it; an armed watchdog covers live failures.
                        try lidWriteJSON(["baselineDisabled": false, "uid": uid,
                                          "at": ISO8601DateFormatter().string(from: Date())], files.receipt)
                        ownsRecovery = true
                        let receipt = open(files.receipt, O_RDONLY | O_NOFOLLOW)
                        guard receipt >= 0 else { throw LidError("Cannot persist recovery receipt") }
                        let persisted = fsync(receipt); close(receipt)
                        guard persisted == 0 else { throw LidError("Cannot persist recovery receipt") }
                        try lidSendCommand(commands.fileHandleForWriting, "arm")
                        try awaitReply("armed")
                        activeSession = requested["session"] as? String ?? ""
                        sessionLimit = LidDuration.seconds(from: requested["durationSeconds"], simulation: simulation)!
                        sessionAllowsBattery = allowBattery
                        sessionReservePercent = reservePercent
                        canStartAgain = false
                        phase = "active"; reason = ""
                        do {
                            try power.setDisabled(true)
                            started = lidTime(); lastSample = 0
                            startedAt = ISO8601DateFormatter().string(from: Date())
                            journal.emit("active", ["clientPID": clientPID, "limitSeconds": sessionLimit,
                                "allowBattery": requested["allowBattery"] as? Bool == true,
                                "batteryReservePercent": sessionReservePercent,
                                "acPower": powerSource.acPower])
                        } catch {
                            reason = "activation-failed"
                            try release(reason)
                            journal.emit("error", ["reason": reason, "error": error.localizedDescription])
                        }
                    }
                } else if (phase == "failed" || phase == "ended") && !wantsPower { phase = "idle" }
                if phase == "active" && now - lastSample >= 30 {
                    journal.emit("sample", ["lidClosed": lidRootProperties()["AppleClamshellState"] ?? false,
                        "displayCount": requested["displayCount"] as? Int ?? -1,
                        "displayQuery": requested["displayQuery"] as? Int ?? -1, "clientFresh": live,
                        "filterReady": requested["ready"] as? Bool == true, "macOSUnlocked": macReady,
                        "acPower": powerSource.acPower,
                        "batteryPercent": powerSource.batteryPercent.map { $0 as Any } ?? NSNull(),
                        "hidIdleSeconds": requested["hidIdleSeconds"] as? Double ?? -1,
                        "sessionIdleSeconds": requested["sessionIdleSeconds"] as? Double ?? -1])
                    lastSample = now
                }
                if now - lastPublished >= 5 || phase != publishedPhase {
                    try? lidWriteJSON(status(), files.state)
                    lastPublished = now; publishedPhase = phase
                }
                if responseNeeded && client >= 0 {
                    do { try lidWriteLine(client, status()) }
                    catch { close(client); client = -1; requested = [:]; try release("app-disconnected") }
                }
                var pending = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: replies.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)]
                if client >= 0 { pending.append(pollfd(fd: client, events: Int16(POLLIN), revents: 0)) }
                _ = poll(&pending, nfds_t(pending.count), Int32((phase == "active" ? min(0.25, lease / 4) : min(1, lease / 3)) * 1000))
            }
        }
        try lidSendCommand(commands.fileHandleForWriting, "stop")
        commands.fileHandleForWriting.closeFile()
        while watchdog.isRunning { usleep(50_000) }
        if client >= 0 { close(client) }
        close(listener); _ = unlink(files.socket)
        close(lock)
        exit(0)
    } catch {
        if ownsRecovery && FileManager.default.fileExists(atPath: files.receipt) {
            // A dead watchdog can close its pipe before Process.isRunning updates.
            // The receipt still assigns recovery to this supervisor in that race.
            lidRestore(power, files: files, journal: journal, reason: "service-error")
        }
        journal.emit("service-error", ["error": error.localizedDescription])
        // Closing the parent pipe also triggers independent recovery. launchd's
        // restart is fenced by the inherited flock until that recovery finishes.
        exit(1)
    }
}
