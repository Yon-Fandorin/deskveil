import Darwin
import Foundation

protocol BrightnessRecoveryStore {
    func load() -> DisplayRecoveryLoad<[String: Float]>
    func save(_ values: [String: Float]) -> Bool
}

/// A present journal that cannot be read or validated still owns recovery.
enum DisplayRecoveryLoad<Value> {
    case absent, loaded(Value), failed
}

extension DisplayRecoveryLoad: Equatable where Value: Equatable {}

/// Current recovery state only. Removed after every saved display is restored.
struct FileBrightnessRecovery: BrightnessRecoveryStore {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoftLock/brightness-recovery.json")
    }
    let url: URL
    init(url: URL = Self.url) { self.url = url }
    static func acquireGuardianLease() -> Int32? {
        let directory = url.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return nil }
        let descriptor = open(directory.appendingPathComponent("brightness.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return nil }
        return descriptor
    }
    func load() -> DisplayRecoveryLoad<[String: Float]> {
        DisplayRecoveryFile.load(from: url) { values in
            values.allSatisfy { !$0.key.isEmpty && $0.value.isFinite && (0...1).contains($0.value) }
        }
    }
    func save(_ values: [String: Float]) -> Bool {
        guard values.allSatisfy({ !$0.key.isEmpty && $0.value.isFinite && (0...1).contains($0.value) }),
              let data = try? JSONEncoder().encode(values) else { return false }
        return DisplayRecoveryFile.save(values.isEmpty ? nil : data, to: url)
    }
}

enum DisplayRecoveryFile {
    static func load<Value: Decodable>(from url: URL, validate: (Value) -> Bool) -> DisplayRecoveryLoad<Value> {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { return isAbsent(url) ? .absent : .failed }
        guard let values = try? JSONDecoder().decode(Value.self, from: data), validate(values) else { return .failed }
        return .loaded(values)
    }
    private static func isAbsent(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) != 0 && errno == ENOENT
    }

    static func save(_ data: Data?, to url: URL) -> Bool {
        do {
            if data == nil {
                do { try FileManager.default.removeItem(at: url) }
                catch { return isAbsent(url) }
            } else if let data {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
                guard descriptor >= 0 else { return false }
                let result = fsync(descriptor); close(descriptor)
                guard result == 0 else { return false }
            }
            return true
        } catch { return false }
    }
}
