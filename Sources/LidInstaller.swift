import Darwin
import Foundation

func printLidInstallationPlan() throws {
    let hash = try lidSignature(Bundle.main.bundleURL.path)
    let identity = try LidInstallationIdentity.current()
    let configuration = identity.configuration
    guard lidPeerIsAllowed(getpid(), uid: getuid(), configuration: configuration),
          !lidPeerIsAllowed(getpid(), uid: getuid(), configuration: ["uid": getuid(),
            "clientRequirement": "cdhash H\"\(String(repeating: "0", count: 40))\""]) else {
        throw LidError(L10n.text("클라이언트 서명 검증을 통과하지 못했습니다."))
    }
    let plan = configuration.merging(["helper": LidPaths.helper, "service": LidPaths.plist,
        "socket": LidPaths.socket, "log": LidPaths.log, "signaturePinned": true,
        "clientHash": hash, "uid": getuid(), "protocol": LidPaths.protocolVersion,
        "powerChanged": false, "installed": false]) { _, value in value }
    let data = try JSONSerialization.data(withJSONObject: plan, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

private func lidValidateRootFile(_ path: String, owner: uid_t = 0) throws {
    var info = stat()
    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          info.st_uid == owner, info.st_mode & 0o022 == 0 else { throw LidError("Unsafe service file: \(path)") }
}

private func lidOwnBundle(_ path: String) throws {
    let root = URL(fileURLWithPath: path)
    guard let entries = FileManager.default.enumerator(at: root,
        includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]) else {
        throw LidError("Cannot inspect helper bundle")
    }
    var urls = [root]
    for case let url as URL in entries { urls.append(url) }
    for url in urls {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
            throw LidError("Unexpected helper bundle entry")
        }
        let executable = url.path.hasSuffix("/Contents/MacOS/SoftLock")
        try FileManager.default.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0,
            .posixPermissions: values.isDirectory == true || executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    }
}

private func lidCallingUser(_ pid: pid_t) throws -> uid_t {
    var path = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
          let own = Bundle.main.executableURL,
          URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path == own.resolvingSymlinksInPath().path else {
        throw LidError(L10n.text("설치를 요청한 DeskVeil을 확인하지 못했습니다."))
    }
    var information = proc_bsdinfo()
    let size = Int32(MemoryLayout.size(ofValue: information))
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, size) == size, information.pbi_uid > 0 else {
        throw LidError(L10n.text("설치 사용자를 확인하지 못했습니다."))
    }
    return information.pbi_uid
}

struct LidInstallationFiles {
    let root: String
    let plist: String
    let socket: String
    let lock: String
    var helper: String { root + "/Helper.app" }
    var executable: String { helper + "/Contents/MacOS/SoftLock" }
    var configuration: String { root + "/service.json" }
    var receipt: String { root + "/recovery.json" }
    var state: String { root + "/state.json" }
    var log: String { root + "/session.jsonl" }

    static let installed = Self(root: LidPaths.root, plist: LidPaths.plist,
                                socket: LidPaths.socket, lock: LidPaths.lock)
}

/// Only the filesystem/OS boundaries of an already authenticated installation
/// are replaceable. The administrator entry point always uses the fixed paths.
struct LidInstallationEnvironment {
    var files: LidInstallationFiles = .installed
    var owner: uid_t = 0
    var lockTimeout: TimeInterval = 15
    var power: LidPowerBackend = NativeLidPower()
    var command: ([String], TimeInterval) throws -> String = { try LidCommand.run($0, timeout: $1) }
    var moveItem: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    var readFile: (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) }
}

private func lidReadInstallationBackup(_ path: String, environment: LidInstallationEnvironment) throws -> Data? {
    var info = stat()
    if lstat(path, &info) != 0 {
        guard errno == ENOENT else { throw LidError(L10n.text("기존 설정을 확인하지 못했습니다: %@", String(describing: path))) }
        return nil
    }
    try lidValidateRootFile(path, owner: environment.owner)
    return try environment.readFile(path)
}

private func lidUnloadService(_ environment: LidInstallationEnvironment) throws {
    if (try? environment.command(["/bin/launchctl", "print", "system/" + LidPaths.label], 3)) != nil {
        _ = try environment.command(["/bin/launchctl", "bootout", "system/" + LidPaths.label], 8)
    }
}

/// Serialize administrator operations separately from the service's recovery
/// lease. Keep this inode after use, including failed or timed-out installations.
func withLidInstallationLock<T>(path: String = "/private/var/tmp/dev.local.softlock.install.lock",
                                owner: uid_t = 0, timeout: TimeInterval = 30,
                                _ operation: () throws -> T) throws -> T {
    guard timeout.isFinite, timeout >= 0 else { throw LidError(L10n.text("설치 잠금 대기 시간이 올바르지 않습니다.")) }
    let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
    guard descriptor >= 0 else { throw LidError(L10n.text("보조 도구 설치 잠금을 열지 못했습니다.")) }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == owner,
          (info.st_mode & S_IFMT) == S_IFREG, info.st_mode & 0o022 == 0 else {
        throw LidError(L10n.text("보조 도구 설치 잠금 파일을 확인하지 못했습니다."))
    }
    let deadline = lidTime() + timeout
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
        guard errno == EWOULDBLOCK || errno == EINTR else { throw LidError(L10n.text("보조 도구 설치 잠금을 얻지 못했습니다.")) }
        guard lidTime() < deadline else { throw LidError(L10n.text("다른 보조 도구 설치가 진행 중입니다. 잠시 후 다시 시도해주세요.")) }
        usleep(50_000)
    }
    return try operation()
}

/// The initial authorization installs a root-owned, signature-pinned capability.
/// This entry point is not exposed over IPC and only operates on fixed paths.
func runLidInstaller(appPID: pid_t, remove: Bool = false) -> Never {
    guard geteuid() == 0 else { fputs("Administrator authorization required\n", stderr); exit(2) }
    do {
        try performLidInstallation(appPID: appPID, remove: remove)
        exit(0)
    } catch {
        fputs(error.localizedDescription + "\n", stderr)
        exit(1)
    }
}

private func performLidInstallation(appPID: pid_t, remove: Bool) throws {
    let uid = try lidCallingUser(appPID)
    try withLidInstallationLock {
        try performLockedLidInstallation(appPID: appPID, uid: uid, remove: remove)
    }
}

private func performLockedLidInstallation(appPID: pid_t, uid: uid_t, remove: Bool) throws {
    try lidEnsureRootDirectory(LidPaths.root)
    let configurationExists = FileManager.default.fileExists(atPath: LidPaths.configuration)
    if configurationExists {
        try lidValidateRootFile(LidPaths.configuration)
        guard try lidJSON(LidPaths.configuration)["uid"] as? UInt32 == uid else {
            throw LidError(L10n.text("다른 사용자가 설치한 보조 도구입니다."))
        }
    }
    if FileManager.default.fileExists(atPath: LidPaths.plist) {
        try lidValidateRootFile(LidPaths.plist)
        let data = try Data(contentsOf: URL(fileURLWithPath: LidPaths.plist))
        let job = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard job?["Label"] as? String == LidPaths.label,
              (job?["ProgramArguments"] as? [String])?.first == LidPaths.executable else {
            throw LidError(L10n.text("기존 서비스가 DeskVeil 보조 도구와 다릅니다."))
        }
    }
    let source = Bundle.main.bundleURL
    let hash = try lidSignature(source.path)
    guard lidPeerIsAllowed(appPID, uid: uid, configuration: ["uid": uid,
        "clientRequirement": "cdhash H\"\(hash)\""]) else {
        throw LidError(L10n.text("실행 중인 앱과 설치 파일의 서명이 다릅니다. DeskVeil을 다시 열어주세요."))
    }
    let stage = URL(fileURLWithPath: LidPaths.root).appendingPathComponent(".install-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    var preserveStage = false
    defer {
        if !preserveStage { try? FileManager.default.removeItem(at: stage) }
        if remove { _ = rmdir(LidPaths.root) }
    }
    let stagedHelper = stage.appendingPathComponent("Helper.app")
    // Freeze the complete signed envelope in a root-only directory before
    // extracting its helper. Re-reading a user-writable source after checking
    // the caller would allow a source swap during administrator authorization.
    let snapshot = stage.appendingPathComponent("Source.app")
    try FileManager.default.copyItem(at: source, to: snapshot)
    try lidOwnBundle(snapshot.path)
    _ = try LidCommand.run(["/bin/chmod", "-RN", snapshot.path], timeout: 8)
    guard try lidSignature(snapshot.path) == hash, let bundle = Bundle(url: snapshot) else {
        throw LidError(L10n.text("설치 도중 앱이 변경됐습니다. DeskVeil을 다시 열어주세요."))
    }
    let identity = try LidInstallationIdentity.current(in: bundle, uid: uid)
    if !remove {
        try FileManager.default.moveItem(at: snapshot.appendingPathComponent(LidPaths.bundledHelper), to: stagedHelper)
        guard try lidSignature(stagedHelper.path) == identity.helperHash else { throw LidError(L10n.text("복사한 보조 도구의 서명이 다릅니다.")) }
    }
    try performLidInstallationTransaction(stage: stage, identity: identity, remove: remove,
                                          preserveStage: &preserveStage)
    print(remove ? "removed" : "installed")
}

/// The complete mutation transaction, shared by installation and removal after
/// caller, bundle, and installed-file authentication in performLidInstallation.
func performLidInstallationTransaction(stage: URL, identity: LidInstallationIdentity, remove: Bool,
                                       environment: LidInstallationEnvironment = .init(),
                                       preserveStage: inout Bool) throws {
    let files = environment.files
    let stagedHelper = stage.appendingPathComponent("Helper.app")
    // Stage everything before stopping the installed version.
    let oldConfiguration = try lidReadInstallationBackup(files.configuration, environment: environment)
    let oldPlist = try lidReadInstallationBackup(files.plist, environment: environment)
    if let oldConfiguration { try oldConfiguration.write(to: stage.appendingPathComponent("previous-service.json")) }
    if let oldPlist { try oldPlist.write(to: stage.appendingPathComponent("previous-job.plist")) }
    let previousHelper = stage.appendingPathComponent("Previous.app")
    var serviceStopped = false
    var previousHelperMoved = false
    var replacementHelperMoved = false
    var configurationChanged = false
    var lock: Int32 = -1
    defer { if lock >= 0 { close(lock) } }
    do {
        try lidUnloadService(environment)
        serviceStopped = true
        lock = open(files.lock, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw LidError(L10n.text("복구 상태를 확인하지 못했습니다.")) }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_uid == environment.owner, (info.st_mode & S_IFMT) == S_IFREG else {
            throw LidError(L10n.text("복구 잠금 파일을 확인하지 못했습니다."))
        }
        let deadline = lidTime() + environment.lockTimeout
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard lidTime() < deadline else { throw LidError(L10n.text("이전 잠자기 설정 복구가 진행 중입니다. 잠시 후 다시 시도해주세요.")) }
            usleep(50_000)
        }
        if FileManager.default.fileExists(atPath: files.receipt) {
            try lidValidateRootFile(files.receipt, owner: environment.owner)
            guard try lidJSON(files.receipt)["baselineDisabled"] as? Bool == false else { throw LidError(L10n.text("복구 기록을 확인하지 못했습니다.")) }
            try environment.power.setDisabled(false)
            try FileManager.default.removeItem(atPath: files.receipt)
        }
        if FileManager.default.fileExists(atPath: files.helper) {
            try environment.moveItem(URL(fileURLWithPath: files.helper), previousHelper)
            previousHelperMoved = true
        }
        if remove {
            // Keep the previous helper staged until every removal has succeeded.
            configurationChanged = true
            for path in [files.plist, files.configuration] where FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
            for path in [files.state, files.log] where FileManager.default.fileExists(atPath: path) {
                try lidValidateRootFile(path, owner: environment.owner)
                try FileManager.default.removeItem(atPath: path)
            }
            _ = unlink(files.socket)
            return
        }
        try environment.moveItem(stagedHelper, URL(fileURLWithPath: files.helper))
        replacementHelperMoved = true
        configurationChanged = true
        try lidWriteJSON(identity.configuration, files.configuration)
        _ = chmod(files.configuration, 0o644)
        let job: [String: Any] = ["Label": LidPaths.label,
            "ProgramArguments": [files.executable, "--lid-service"],
            "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 5,
            "ProcessType": "Background", "ExitTimeOut": 10]
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: files.plist), options: .atomic)
        _ = chmod(files.plist, 0o644)
        flock(lock, LOCK_UN)
        _ = try environment.command(["/bin/launchctl", "bootstrap", "system", files.plist], 8)
    } catch {
        guard serviceStopped else { throw error }
        try? lidUnloadService(environment)
        if replacementHelperMoved { try? FileManager.default.removeItem(atPath: files.helper) }
        if previousHelperMoved {
            do { try environment.moveItem(previousHelper, URL(fileURLWithPath: files.helper)) }
            catch {
                preserveStage = true
                throw LidError(L10n.text("기존 보조 도구를 복원하지 못했습니다. 원본은 %@에 보존했습니다.", String(describing: previousHelper.path)))
            }
        }
        do {
            if configurationChanged {
                for (data, path) in [(oldConfiguration, files.configuration), (oldPlist, files.plist)] {
                    if let data { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
                    else if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
                }
            }
            if oldPlist != nil {
                if lock >= 0 { flock(lock, LOCK_UN) }
                _ = try environment.command(["/bin/launchctl", "bootstrap", "system", files.plist], 8)
            }
        } catch {
            preserveStage = true
            throw LidError(L10n.text("설치 실패 후 이전 설정의 복구를 확인하지 못했습니다. 복구 파일은 %@에 보존했습니다. %@", String(describing: stage.path), String(describing: error.localizedDescription)))
        }
        throw error
    }
}
