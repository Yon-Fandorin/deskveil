import AppKit
import CoreGraphics
import Darwin

/// Observations of macOS display output, never a claim about a monitor's power button.
struct DisplayStatus: Equatable {
    let id: UInt32
    let name: String
    let builtIn: Bool
    let asleep: Bool
    let active: Bool
    let brightness: Float?
    let blackOutput: Bool?
    var identity: String? = nil

    var label: String {
        if asleep { return L10n.text("잠자기") }
        if !active { return L10n.text("비활성") }
        if blackOutput == true { return L10n.text("검은 화면 출력") }
        if let brightness, brightness <= 0.005 { return L10n.text("최저 밝기") }
        return L10n.text("출력 활성")
    }
    var subdued: Bool { asleep || !active || blackOutput == true }
    var brightnessPercent: Int? {
        guard let brightness, brightness.isFinite, (0...1).contains(brightness) else { return nil }
        return Int((brightness * 100).rounded())
    }
    func withFallbackBrightness(_ value: Float?) -> Self {
        guard brightness == nil, active, !asleep, let value,
              DisplayBrightnessObservation.valid(value) else { return self }
        return Self(id: id, name: name, builtIn: builtIn, asleep: asleep, active: active,
                    brightness: value, blackOutput: blackOutput, identity: identity)
    }
}

/// Read-only sampling. No DDC transactions, recovery writes, wake signals or assertions.
final class DisplayStatusReader {
    private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private let library: UnsafeMutableRawPointer?
    private let get: Get?
    private let identities = NativeDDCBrightness()

    init() {
        library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        if let library, let symbol = dlsym(library, "DisplayServicesGetBrightness") {
            get = unsafeBitCast(symbol, to: Get.self)
        } else { get = nil }
    }
    deinit { if let library { dlclose(library) } }

    func read() -> [DisplayStatus]? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        guard count > 0 else { return [] }
        var ids = [UInt32](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        let names = Dictionary(NSScreen.screens.compactMap { screen -> (UInt32, String)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (id.uint32Value, screen.localizedName)
        }, uniquingKeysWith: { first, _ in first })
        let stableIDs = Dictionary(uniqueKeysWithValues: ids.prefix(Int(count)).map { ($0, identities.identity($0)) })
        let counts = Dictionary(stableIDs.values.compactMap { $0 }.map { ($0, 1) }, uniquingKeysWith: +)
        return ids.prefix(Int(count)).sorted().map { id in
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let asleep = CGDisplayIsAsleep(id) != 0
            let active = CGDisplayIsActive(id) != 0
            var value: Float = 0
            var brightness: Float?
            var blackOutput: Bool?
            if !asleep && active {
                if get?(id, &value) == 0, value.isFinite, (0...1).contains(value) { brightness = value }
                if let table = DisplayGammaTable.read(id) {
                    blackOutput = [table.red, table.green, table.blue].allSatisfy { $0.allSatisfy { $0 <= 0.002 } }
                }
            }
            return DisplayStatus(id: id, name: names[id] ?? (builtIn ? L10n.text("내장 디스플레이") : L10n.text("디스플레이 %@", String(describing: id))),
                builtIn: builtIn, asleep: asleep, active: active, brightness: brightness, blackOutput: blackOutput,
                identity: stableIDs[id].flatMap { $0 }.flatMap { counts[$0] == 1 ? $0 : nil })
        }
    }
}
