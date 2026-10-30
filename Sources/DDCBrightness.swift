import CoreGraphics
import Darwin
import Foundation
import IOKit

/// Only the MCCS brightness feature is exposed; no power/input/standby commands.
enum DDCBrightnessPacket {
    static let query: [UInt8] = [0x82, 0x01, 0x10, 0xfd]

    static func set(_ value: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [0x84, 0x03, 0x10, UInt8(value >> 8), UInt8(value & 255)]
        bytes.append(bytes.reduce(0x6e ^ 0x51, ^))
        return bytes
    }

    static func decode(_ bytes: [UInt8]) -> (current: UInt16, maximum: UInt16)? {
        guard bytes.count == 11, bytes[0...4].elementsEqual([0x6e, 0x88, 0x02, 0, 0x10]),
              bytes.reduce(UInt8(0x50), ^) == 0 else { return nil }
        let maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let current = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        guard maximum > 0, current <= maximum else { return nil }
        return (current, maximum)
    }
}

/// A route is valid only for this display identity and these registry objects.
/// The retained service is deliberately excluded from route equality.
struct DDCBrightnessRoute: Equatable {
    let identity: String
    let framebufferID: UInt64
    let proxyID: UInt64
    var service: CFTypeRef? = nil
    var chip: UInt32 = 0x37
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity && lhs.framebufferID == rhs.framebufferID &&
            lhs.proxyID == rhs.proxyID && lhs.chip == rhs.chip
    }
}

protocol DDCBrightnessTransport {
    func identity(_ display: UInt32) -> String?
    func route(_ display: UInt32, identity: String) -> DDCBrightnessRoute?
    func read(_ route: DDCBrightnessRoute) -> (current: UInt16, maximum: UInt16)?
    func write(_ route: DDCBrightnessRoute, value: UInt16) -> Bool
}

/// Cache only values belonging to a freshly validated route. A known UUID does
/// not authorize sending to a retained service after a disconnect or port move.
final class NativeDDCBrightness {
    private struct Connection {
        let route: DDCBrightnessRoute
        var maximum: UInt16 = 0
        var current: UInt16?
    }
    private let transport: DDCBrightnessTransport
    private var connections: [String: Connection] = [:]
    init(transport: DDCBrightnessTransport = NativeDDCTransport()) { self.transport = transport }
    deinit { connections.removeAll() }
    func identity(_ display: UInt32) -> String? { transport.identity(display) }
    func known(_ identity: String) -> Bool { (connections[identity]?.maximum ?? 0) > 0 }

    private func connect(_ display: UInt32, identity: String) -> Bool {
        guard transport.identity(display) == identity,
              let route = transport.route(display, identity: identity), route.identity == identity else {
            connections.removeValue(forKey: identity); return false
        }
        let previous = connections[identity].flatMap { $0.route == route ? $0 : nil }
        connections[identity] = Connection(route: route, maximum: previous?.maximum ?? 0, current: previous?.current)
        return true
    }
    func read(_ display: UInt32, identity: String) -> Float? {
        guard connect(display, identity: identity), var connection = connections[identity],
              let value = transport.read(connection.route), value.maximum > 0, value.current <= value.maximum else {
            connections.removeValue(forKey: identity); return nil
        }
        connection.maximum = value.maximum; connection.current = value.current
        connections[identity] = connection
        return Float(value.current) / Float(value.maximum)
    }
    func write(_ display: UInt32, identity: String, value: Float, verify: Bool) -> Bool {
        guard value.isFinite, (0...1).contains(value), connect(display, identity: identity) else { return false }
        if !known(identity), read(display, identity: identity) == nil { return false }
        // Reading an unknown route can take time. Validate once more immediately
        // before the write, and abort if its maximum belongs to an older route.
        guard let expected = connections[identity]?.route,
              connect(display, identity: identity), var connection = connections[identity],
              connection.route == expected, connection.maximum > 0 else { return false }
        let raw = UInt16((value * Float(connection.maximum)).rounded())
        if connection.current != raw {
            guard transport.write(connection.route, value: raw) else {
                connections.removeValue(forKey: identity); return false
            }
            connection.current = raw; connections[identity] = connection
        }
        guard verify else { return true }
        guard read(display, identity: identity) != nil else { return false }
        return connections[identity]?.route == expected && connections[identity]?.current == raw
    }
}

/// Private IOAV transactions run only in the independent brightness guardian.
final class NativeDDCTransport: DDCBrightnessTransport {
    private typealias Info = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?
    private typealias Create = @convention(c) (CFAllocator?, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32

    private var libraries: [UnsafeMutableRawPointer] = []
    private var info: Info?
    private var create: Create?
    private var readI2C: Transfer?
    private var writeI2C: Transfer?

    init() {
        if let core = dlopen("/System/Library/Frameworks/CoreDisplay.framework/Versions/A/CoreDisplay", RTLD_LAZY) {
            libraries.append(core)
            if let symbol = dlsym(core, "CoreDisplay_DisplayCreateInfoDictionary") { info = unsafeBitCast(symbol, to: Info.self) }
        }
        #if arch(arm64)
        if let kit = dlopen("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", RTLD_LAZY) {
            libraries.append(kit)
            if let symbol = dlsym(kit, "IOAVServiceCreateWithService") { create = unsafeBitCast(symbol, to: Create.self) }
            if let symbol = dlsym(kit, "IOAVServiceReadI2C") { readI2C = unsafeBitCast(symbol, to: Transfer.self) }
            if let symbol = dlsym(kit, "IOAVServiceWriteI2C") { writeI2C = unsafeBitCast(symbol, to: Transfer.self) }
        }
        #endif
    }

    deinit {
        libraries.forEach { dlclose($0) }
    }

    func identity(_ display: UInt32) -> String? {
        (info?(display)?.takeRetainedValue() as? [String: Any])?["kCGDisplayUUID"] as? String
    }
    func read(_ route: DDCBrightnessRoute) -> (current: UInt16, maximum: UInt16)? {
        guard let service = route.service, let writeI2C, let readI2C else { return nil }
        for _ in 0..<2 {
            var request = DDCBrightnessPacket.query
            var sent = true
            for _ in 0..<2 {
                usleep(10_000)
                if request.withUnsafeMutableBytes({ writeI2C(service, route.chip, 0x51, $0.baseAddress!, UInt32($0.count)) }) != 0 { sent = false; break }
            }
            if sent {
                usleep(50_000)
                var reply = [UInt8](repeating: 0, count: 11)
                let result = reply.withUnsafeMutableBytes { readI2C(service, route.chip, 0, $0.baseAddress!, UInt32($0.count)) }
                if result == 0, let value = DDCBrightnessPacket.decode(reply) {
                    return value
                }
            }
            usleep(20_000)
        }
        return nil
    }
    func write(_ route: DDCBrightnessRoute, value: UInt16) -> Bool {
        guard let service = route.service, let writeI2C else { return false }
        var packet = DDCBrightnessPacket.set(value)
        for _ in 0..<2 {
            usleep(10_000)
            guard packet.withUnsafeMutableBytes({ writeI2C(service, route.chip, 0x51, $0.baseAddress!, UInt32($0.count)) }) == 0 else { return false }
        }
        return true
    }
    func route(_ display: UInt32, identity: String) -> DDCBrightnessRoute? {
        guard let info = info?(display)?.takeRetainedValue() as? [String: Any],
              info["kCGDisplayUUID"] as? String == identity,
              let path = info["IODisplayLocation"] as? String, let create else { return nil }
        let framebuffer = IORegistryEntryCopyFromPath(kIOMainPortDefault, path as CFString)
        guard framebuffer != 0 else { return nil }
        defer { IOObjectRelease(framebuffer) }
        var selectedID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(framebuffer, &selectedID) == KERN_SUCCESS else { return nil }
        // On Apple Silicon the AV proxy is not a child of the framebuffer shim.
        // Match the framebuffer's registry ID in IOService traversal order, then
        // inspect only its associated block before the next framebuffer.
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var candidate: DDCBrightnessRoute?
        var matchedFramebuffer = false
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            if IOObjectConformsTo(entry, "IOMobileFramebuffer") != 0 {
                if matchedFramebuffer { break }
                var entryID: UInt64 = 0
                matchedFramebuffer = IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS && entryID == selectedID
                continue
            }
            guard matchedFramebuffer else { continue }
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS, String(cString: name) == "DCPAVServiceProxy",
                  let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                  location == "External", let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            var parent: io_registry_entry_t = 0
            var chip: UInt32 = 0x37
            if IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS {
                if let provider = IORegistryEntryCreateCFProperty(parent, "EPICProviderClass" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                   provider == "AppleDCPMCDP29XX" { chip = 0xb7 }
                IOObjectRelease(parent)
            }
            // Do not guess a route if a framebuffer exposes multiple candidates.
            if candidate != nil { return nil }
            var proxyID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &proxyID) == KERN_SUCCESS else { return nil }
            candidate = DDCBrightnessRoute(identity: identity, framebufferID: selectedID, proxyID: proxyID, service: service, chip: chip)
        }
        guard let candidate else { return nil }
        return candidate
    }
}
