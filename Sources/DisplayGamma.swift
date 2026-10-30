import CoreGraphics
import Foundation

struct DisplayGammaTable: Codable, Equatable {
    let red: [Float]
    let green: [Float]
    let blue: [Float]

    var valid: Bool {
        (2...65536).contains(red.count) && green.count == red.count && blue.count == red.count &&
            [red, green, blue].allSatisfy { $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }
    }
    func scaled(_ factor: Float) -> Self {
        Self(red: red.map { $0 * factor }, green: green.map { $0 * factor }, blue: blue.map { $0 * factor })
    }
    func matches(_ other: Self) -> Bool {
        valid && other.valid && red.count == other.red.count &&
            [(red, other.red), (green, other.green), (blue, other.blue)].allSatisfy { pair in
                zip(pair.0, pair.1).allSatisfy { abs($0 - $1) < 0.002 }
            }
    }
    static func read(_ display: UInt32) -> Self? {
        let capacity = CGDisplayGammaTableCapacity(display)
        guard (2...65536).contains(capacity) else { return nil }
        var red = [Float](repeating: 0, count: Int(capacity))
        var green = red, blue = red, samples: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &samples) == .success,
              samples > 1, samples <= capacity else { return nil }
        let table = Self(red: Array(red.prefix(Int(samples))), green: Array(green.prefix(Int(samples))),
                         blue: Array(blue.prefix(Int(samples))))
        return table.valid ? table : nil
    }
    static func write(_ display: UInt32, table: Self) -> Bool {
        guard table.valid else { return false }
        return CGSetDisplayTransferByTable(display, UInt32(table.red.count), table.red, table.green, table.blue) == .success
    }
}

protocol GammaRecoveryStore {
    func load() -> DisplayRecoveryLoad<[String: DisplayGammaTable]>
    func save(_ values: [String: DisplayGammaTable]) -> Bool
}

struct FileGammaRecovery: GammaRecoveryStore {
    static var url: URL { FileBrightnessRecovery.url.deletingLastPathComponent().appendingPathComponent("gamma-recovery.json") }
    let url: URL
    init(url: URL = Self.url) { self.url = url }
    func load() -> DisplayRecoveryLoad<[String: DisplayGammaTable]> {
        DisplayRecoveryFile.load(from: url) { values in
            values.allSatisfy { !$0.key.isEmpty && $0.value.valid }
        }
    }
    func save(_ values: [String: DisplayGammaTable]) -> Bool {
        guard values.allSatisfy({ !$0.key.isEmpty && $0.value.valid }),
              let data = try? JSONEncoder().encode(values) else { return false }
        return DisplayRecoveryFile.save(values.isEmpty ? nil : data, to: url)
    }
}

/// Display output only: no overlay, focus change, display sleep or disconnection.
/// The brightness guardian owns both this recovery state and physical brightness.
final class ExternalBlackout {
    private let read: (UInt32) -> DisplayGammaTable?
    private let write: (UInt32, DisplayGammaTable) -> Bool
    private let recovery: GammaRecoveryStore
    private var originals: [String: DisplayGammaTable] = [:]
    private(set) var recoveryLoadFailed = false
    private var emptyRecoveryPending = false
    var pendingIdentities: Set<String> { Set(originals.keys) }
    var hasPendingRestore: Bool { recoveryLoadFailed || emptyRecoveryPending || !originals.isEmpty }

    init(read: @escaping (UInt32) -> DisplayGammaTable? = DisplayGammaTable.read,
         write: @escaping (UInt32, DisplayGammaTable) -> Bool = DisplayGammaTable.write,
         recovery: GammaRecoveryStore = FileGammaRecovery()) {
        self.read = read; self.write = write; self.recovery = recovery
        switch recovery.load() {
        case .loaded(let values): originals = values; emptyRecoveryPending = values.isEmpty
        case .failed: recoveryLoadFailed = true
        case .absent: break
        }
    }
    /// Only restoration can resolve an unreadable journal. Missing data after
    /// an earlier failure cannot establish that the unknown original is restored.
    func reloadRecoveryForRestore() -> Bool {
        if recoveryLoadFailed, case .loaded(let values) = recovery.load() {
            originals.merge(values) { original, _ in original }
            recoveryLoadFailed = false
            emptyRecoveryPending = originals.isEmpty
        }
        return !recoveryLoadFailed
    }
    func clearEmptyRecoveryForRestore() -> Bool {
        guard !recoveryLoadFailed else { return false }
        guard emptyRecoveryPending else { return true }
        guard originals.isEmpty, recovery.save([:]) else { return false }
        emptyRecoveryPending = false
        return true
    }
    func prepare(_ display: UInt32, identity: String, isCurrent: () -> Bool = { true }) -> Bool {
        guard !recoveryLoadFailed, isCurrent() else { return false }
        if originals[identity] != nil { return true }
        guard let table = read(display), table.valid, isCurrent() else { return false }
        var next = originals; next[identity] = table
        guard recovery.save(next) else { return false }
        originals = next; emptyRecoveryPending = false
        return isCurrent()
    }
    func apply(_ display: UInt32, identity: String, factor: Float, verify: Bool, isCurrent: () -> Bool = { true }) -> Bool {
        guard !recoveryLoadFailed, factor.isFinite, (0...1).contains(factor), let original = originals[identity], isCurrent() else { return false }
        let target = original.scaled(factor)
        guard write(display, target), isCurrent() else { return false }
        return (!verify || read(display).map { $0.matches(target) } == true) && isCurrent()
    }
    func enforce(_ display: UInt32, identity: String, isCurrent: () -> Bool = { true }) -> Bool {
        guard !recoveryLoadFailed else { return false }
        guard let original = originals[identity] else { return true }
        guard isCurrent() else { return false }
        if read(display).map({ $0.matches(original.scaled(0)) }) == true { return isCurrent() }
        return apply(display, identity: identity, factor: 0, verify: true, isCurrent: isCurrent)
    }
    func restore(_ display: UInt32, identity: String, isCurrent: () -> Bool = { true }) -> Bool {
        guard reloadRecoveryForRestore(), clearEmptyRecoveryForRestore() else { return false }
        guard let original = originals[identity] else { return true }
        guard isCurrent(), write(display, original), isCurrent(),
              read(display).map({ $0.matches(original) }) == true, isCurrent() else { return false }
        var next = originals; next.removeValue(forKey: identity)
        guard recovery.save(next) else { return false }
        originals = next; emptyRecoveryPending = false
        return true
    }
}
