import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import IOKit
import IOKit.ps
import Security
import SystemConfiguration

enum LidPaths {
    static let label = "dev.local.softlock.power"
    static let root = "/Library/Application Support/SoftLock"
    static let helper = root + "/Helper.app"
    static let executable = helper + "/Contents/MacOS/SoftLock"
    static let bundledHelper = "Contents/Helpers/SoftLockPower.app"
    static let configuration = root + "/service.json"
    static let log = root + "/session.jsonl"
    static let state = root + "/state.json"
    static let receipt = root + "/recovery.json"
    static let plist = "/Library/LaunchDaemons/" + label + ".plist"
    static let socket = "/private/var/run/softlock-power/control.sock"
    static let lock = "/private/var/tmp/dev.local.softlock.power.lock"
    static let protocolVersion = 4
    static let lease: TimeInterval = 6
}

func lidTime() -> TimeInterval {
    var scale = mach_timebase_info_data_t()
    mach_timebase_info(&scale)
    return Double(mach_continuous_time()) * Double(scale.numer) / Double(scale.denom) / 1e9
}

struct LidError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func lidJSON(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.count <= 1_100_000,
          let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw LidError("Invalid power service data")
    }
    return value
}

func lidWriteJSON(_ value: [String: Any], _ path: String) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        .write(to: URL(fileURLWithPath: path), options: .atomic)
    if geteuid() == 0 { _ = chmod(path, 0o644) }
}

func lidEnsureRootDirectory(_ path: String, mode: mode_t = 0o755) throws {
    var info = stat()
    if lstat(path, &info) == 0 {
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == 0,
              info.st_mode & 0o022 == 0 else { throw LidError("Unsafe service directory: \(path)") }
    } else {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: mode), .ownerAccountID: 0, .groupOwnerAccountID: 0])
    }
}

func lidConsoleUserIs(_ expected: uid_t) -> Bool {
    var uid: uid_t = 0, gid: gid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String? else { return false }
    return name != "loginwindow" && uid == expected
}

private func lidSigningInformation(_ path: String) throws -> [String: Any] {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
          let code, SecStaticCodeCheckValidity(code,
            SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess else {
        throw LidError(L10n.text("앱 서명을 확인하지 못했습니다."))
    }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let information = information as? [String: Any] else {
        throw LidError(L10n.text("앱 서명 정보를 읽지 못했습니다."))
    }
    return information
}

func lidSignature(_ path: String) throws -> String {
    guard let digest = try lidSigningInformation(path)[kSecCodeInfoUnique as String] as? Data else {
        throw LidError(L10n.text("앱 서명 해시를 읽지 못했습니다."))
    }
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Pin the exact signer and identifier, so a differently signed namesake cannot
/// connect. Explicit ad-hoc builds still require a new approval after rebuilding.
func lidClientRequirement(_ path: String) throws -> String {
    let information = try lidSigningInformation(path)
    guard let identifier = information[kSecCodeInfoIdentifier as String] as? String,
          !identifier.isEmpty, identifier.utf8.allSatisfy({
              (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46].contains($0)
          }) else { throw LidError(L10n.text("앱 서명 식별자를 확인하지 못했습니다.")) }
    if let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate],
       let leaf = certificates.first {
        let hash = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02x", $0) }.joined()
        return "identifier \"\(identifier)\" and certificate leaf = H\"\(hash)\""
    }
    return "cdhash H\"\(try lidSignature(path))\""
}

struct LidInstallationIdentity {
    let uid: uid_t
    let clientRequirement: String
    let helperHash: String

    static func current(in bundle: Bundle = .main, uid: uid_t = getuid()) throws -> Self {
        Self(uid: uid, clientRequirement: try lidClientRequirement(bundle.bundleURL.path),
             helperHash: try lidSignature(bundle.bundleURL.appendingPathComponent(LidPaths.bundledHelper).path))
    }

    var configuration: [String: Any] {
        ["uid": uid, "clientRequirement": clientRequirement, "helperHash": helperHash,
         "protocol": LidPaths.protocolVersion]
    }

    func matches(_ configuration: [String: Any]) -> Bool {
        configuration["uid"] as? UInt32 == uid &&
        configuration["clientRequirement"] as? String == clientRequirement &&
        configuration["helperHash"] as? String == helperHash &&
        configuration["protocol"] as? Int == LidPaths.protocolVersion
    }
}

func lidPeerIsAllowed(_ pid: pid_t, uid: uid_t, configuration: [String: Any]) -> Bool {
    guard configuration["uid"] as? UInt32 == uid,
          let expression = configuration["clientRequirement"] as? String,
          !expression.isEmpty, expression.utf8.count <= 4096 else { return false }
    var code: SecCode?
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess else { return false }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
}

/// Child mutations explicitly share the supervisor's process group. Recovery kills
/// that group before writing 0, including a command whose supervisor was killed.
enum LidCommand {
    static func run(_ arguments: [String], timeout: TimeInterval = 3, onLaunch: ((pid_t) -> Void)? = nil) throws -> String {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw LidError("Cannot create command pipe") }
        defer { close(descriptors[0]); close(descriptors[1]) }
        _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)
        let sink = open("/dev/null", O_RDWR)
        guard sink >= 0 else { throw LidError("Cannot open command output") }
        defer { close(sink) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, sink, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, sink, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, descriptors[0])
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, getpgrp())
        var argv = arguments.map { strdup($0) } + [nil]
        var environment = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), nil]
        defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, arguments[0], &actions, &attributes, &argv, &environment)
        guard result == 0 else { throw LidError("Command launch failed: \(result)") }
        onLaunch?(pid)
        var output = Data()
        var status: Int32 = 0
        let deadline = lidTime() + timeout
        while true {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = read(descriptors[0], &bytes, bytes.count)
            if count > 0 && output.count < 65536 { output.append(contentsOf: bytes.prefix(count)) }
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if (waited < 0 && errno != EINTR) || lidTime() >= deadline {
                kill(pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                throw LidError("Power command timed out or became unavailable")
            }
            usleep(10_000)
        }
        while true {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = read(descriptors[0], &bytes, bytes.count)
            guard count > 0 else { break }
            if output.count < 65536 { output.append(contentsOf: bytes.prefix(count)) }
        }
        guard status == 0 else { throw LidError("Power command failed: \(status)") }
        return String(decoding: output, as: UTF8.self)
    }
}

func lidRootProperties() -> [String: Bool] {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return [:] }
    defer { IOObjectRelease(service) }
    var result: [String: Bool] = [:]
    for key in ["SleepDisabled", "AppleClamshellState"] {
        result[key] = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }
    return result
}

protocol LidPowerBackend {
    func disabled() throws -> Bool
    func configuredDisabled() throws -> Bool
    func setDisabled(_ value: Bool) throws
}

struct NativeLidPower: LidPowerBackend {
    private typealias CopySettings = @convention(c) () -> Unmanaged<CFDictionary>?
    private static let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static let copySettings: CopySettings? = library.flatMap { dlsym($0, "IOPMCopySystemPowerSettings") }
        .map { unsafeBitCast($0, to: CopySettings.self) }

    func disabled() throws -> Bool {
        guard let value = lidRootProperties()["SleepDisabled"] else { throw LidError("Power state unavailable") }
        return value
    }
    func configuredDisabled() throws -> Bool {
        // The same read API pmset uses, without spawning a command for each check.
        guard let copy = Self.copySettings,
              let settings = copy()?.takeRetainedValue() as? [String: Any],
              let value = settings["SleepDisabled"] as? Bool else { throw LidError("Saved power state unavailable") }
        return value
    }
    func setDisabled(_ value: Bool) throws {
        guard geteuid() == 0 else { throw LidError("Administrator authorization required") }
        _ = try LidCommand.run(["/usr/bin/pmset", "-a", "disablesleep", value ? "1" : "0"])
        guard try configuredDisabled() == value else { throw LidError("Power state not saved") }
        let deadline = lidTime() + 2
        while try disabled() != value {
            guard lidTime() < deadline else { throw LidError("Power state not applied") }
            usleep(50_000)
        }
    }
}

final class LidJournal {
    let path: String
    init(_ path: String) { self.path = path }
    func emit(_ event: String, _ fields: [String: Any] = [:]) {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFREG else { return }
        // Diagnostics must never wait behind another reader's advisory lock:
        // both the supervisor and its independent recovery watchdog use this log.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { flock(fd, LOCK_UN) }
        if info.st_size >= 1_048_576 { ftruncate(fd, 0) }
        var record = fields
        record["event"] = event
        record["at"] = ISO8601DateFormatter().string(from: Date())
        record["continuous"] = lidTime()
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(10)
        data.withUnsafeBytes { bytes in _ = write(fd, bytes.baseAddress, bytes.count) }
    }
}

func lidSocketAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw LidError("Socket path too long") }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { target in
        target.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
    }
    return address
}

func lidWithAddress<T>(_ address: inout sockaddr_un, _ action: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { action($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

func lidWriteLine(_ fd: Int32, _ value: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    data.append(10)
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = write(fd, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
            guard count > 0 else { throw LidError("Power service connection ended") }
            offset += count
        }
    }
}
