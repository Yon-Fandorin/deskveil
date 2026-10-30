import AppKit

extension SessionEndReason {
    var needsPrivacyShield: Bool {
        switch self {
        case .tapInterrupted, .tapUnavailable, .secureInput, .filterReleased, .unresponsive,
             .brightnessGuardianExit, .coverFailure, .powerUnavailable, .lidEnded: return true
        default: return false
        }
    }
}

protocol PrivacyShieldSurface: AnyObject {
    var presented: Bool { get }
    func show()
    func hide()
}

/// A separate, explicitly dismissed visual latch. It does not claim to block
/// input, authenticate the user, or replace the input/power recovery owners.
final class PrivacyShield {
    private let surface: PrivacyShieldSurface
    private let clock: () -> TimeInterval
    private let automaticPolling: Bool
    private var timer: Timer?
    private var latchGeneration: UInt64 = 0
    private var startedAt: TimeInterval = 0
    private(set) var active = false
    private(set) var presented = false
    private(set) var presentationFailed = false
    var awaitingPresentation: Bool { active && !presented && !presentationFailed }
    var onPresented: (() -> Void)?
    var onPresentationFailure: (() -> Void)?
    var onChange: (() -> Void)?

    init(surface: PrivacyShieldSurface = NativePrivacyShieldSurface(), automaticPolling: Bool = true,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.surface = surface; self.automaticPolling = automaticPolling; self.clock = clock
    }
    deinit { timer?.invalidate() }
    @discardableResult func begin(reason: SessionEndReason, sessionActive: Bool, macOSLocked: Bool) -> Bool {
        guard !active, sessionActive, !macOSLocked, reason.needsPrivacyShield else { return false }
        latchGeneration &+= 1
        active = true; presentationFailed = false
        startedAt = clock()
        rebuild()
        return true
    }
    func rebuild() {
        guard active else { return }
        let latchGeneration = latchGeneration
        presented = false
        surface.show()
        // Keep an in-flight timer through topology bursts so notifications
        // cannot keep postponing the original presentation deadline.
        if automaticPolling && timer == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self, self.latchGeneration == latchGeneration else { return }
                self.pollPresentation()
            }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        onChange?()
    }
    func pollPresentation() {
        guard active, !presented else { return }
        if surface.presented {
            presented = true; presentationFailed = false
            timer?.invalidate(); timer = nil
            onPresented?(); onChange?()
        } else if !presentationFailed, clock() - startedAt >= 2 {
            presentationFailed = true; onPresentationFailure?(); onChange?()
        }
    }
    func dismiss() {
        guard active else { return }
        latchGeneration &+= 1; timer?.invalidate(); timer = nil
        active = false; presented = false; presentationFailed = false
        surface.hide(); onChange?()
    }
}

/// Nonactivating windows catch pointer clicks so they cannot reach the desktop.
/// Recovery stays outside the publicly visible surface.
final class NativePrivacyShieldSurface: NSObject, PrivacyShieldSurface {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private var panels: [(NSPanel, CGDirectDisplayID)] = []
    var presented: Bool {
        let displays = Set(NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        })
        guard !displays.isEmpty, Set(panels.map { $0.1 }) == displays else { return false }
        return panels.allSatisfy { panel, display in
            guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(panel.windowNumber)) as? [[String: Any]],
                  let row = rows.first, row[kCGWindowIsOnscreen as String] as? Bool == true,
                  let alpha = row[kCGWindowAlpha as String] as? Double, alpha >= 0.999,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.contains(CGDisplayBounds(display))
        }
    }
    func show() {
        let next = NSScreen.screens.compactMap { screen -> (NSPanel, CGDirectDisplayID)? in
            guard let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let frame = screen.frame.insetBy(dx: -screen.frame.width / 8, dy: -screen.frame.height / 8)
            let panel = Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.backgroundColor = .black; panel.isOpaque = true; panel.hasShadow = false
            panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false; panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.animationBehavior = .none
            let content = PrivacyShieldContent()
            content.fitSurface(to: frame.size, visibleSize: screen.frame.size)
            panel.contentView = content
            panel.setAccessibilityLabel(L10n.text("DeskVeil 화면 가림"))
            panel.orderFrontRegardless(); panel.displayIfNeeded()
            return (panel, display.uint32Value)
        }
        guard !next.isEmpty, next.allSatisfy({ $0.0.isVisible }) else {
            for (panel, _) in next { panel.close() }; return
        }
        let previous = panels; panels = next
        for (panel, _) in previous { panel.orderOut(nil); panel.close() }
    }
    func hide() {
        for (panel, _) in panels { panel.orderOut(nil); panel.close() }
        panels = []
    }
}
