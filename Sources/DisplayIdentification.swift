import AppKit

struct DisplayIdentification: Equatable {
    let displayID: UInt32
    let identity: String
    let name: String
    let number: Int

    static func resolve(_ selected: DisplayStatus, current: [DisplayStatus]) -> Self? {
        guard let identity = selected.identity,
              current.filter({ $0.identity == identity }).count == 1,
              let index = current.firstIndex(where: { $0.id == selected.id && $0.identity == identity }) else { return nil }
        let display = current[index]
        guard !display.subdued, display.brightnessPercent != 0 else { return nil }
        return Self(displayID: display.id, identity: identity, name: display.name, number: index + 1)
    }
}

/// A brief visual marker. Never changes display brightness, gamma or sleep state.
final class DisplayIdentifier {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private final class Marker: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 9, dy: 9), xRadius: 18, yRadius: 18)
            outline.lineWidth = 4
            outline.stroke()
        }
    }
    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?
    var isVisible: Bool { panel?.isVisible == true }
    var markerView: NSView? { panel?.contentView }
    var snapshot: [String: Any] {
        ["visible": isVisible, "frame": NSStringFromRect(panel?.frame ?? .zero),
         "key": panel?.isKeyWindow ?? false, "canBecomeKey": panel?.canBecomeKey ?? false,
         "ignoresMouse": panel?.ignoresMouseEvents ?? false]
    }
    deinit { dismissal?.cancel(); panel?.orderOut(nil); panel?.close() }

    @discardableResult func show(_ identification: DisplayIdentification, in frame: NSRect) -> Bool {
        hide()
        guard frame.width.isFinite, frame.height.isFinite, frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width >= 200, frame.height >= 160 else { return false }
        let next = Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        next.backgroundColor = .clear; next.isOpaque = false; next.hasShadow = false
        next.isReleasedWhenClosed = false; next.hidesOnDeactivate = false
        next.ignoresMouseEvents = true; next.level = .floating
        next.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        next.animationBehavior = .none; next.setAccessibilityElement(false)
        let marker = Marker(frame: NSRect(origin: .zero, size: frame.size))
        let badgeWidth = min(260, frame.width - 32)
        let badge = NSVisualEffectView(frame: NSRect(x: (frame.width - badgeWidth) / 2,
            y: (frame.height - 140) / 2, width: badgeWidth, height: 140))
        badge.material = .hudWindow; badge.blendingMode = .withinWindow; badge.state = .active
        badge.appearance = NSAppearance(named: .vibrantDark)
        badge.wantsLayer = true; badge.layer?.cornerRadius = 18; badge.layer?.masksToBounds = true
        badge.layer?.borderWidth = 1; badge.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        func label(_ text: String, size: CGFloat, weight: NSFont.Weight, frame: NSRect, alpha: CGFloat = 1) {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = .white.withAlphaComponent(alpha)
            field.alignment = .center; field.lineBreakMode = .byTruncatingMiddle
            field.frame = frame; badge.addSubview(field)
        }
        label(L10n.text("디스플레이"), size: 11, weight: .medium, frame: NSRect(x: 18, y: 110, width: badgeWidth - 36, height: 16), alpha: 0.7)
        label(String(identification.number), size: 46, weight: .semibold, frame: NSRect(x: 18, y: 48, width: badgeWidth - 36, height: 58))
        label(identification.name, size: 13, weight: .medium, frame: NSRect(x: 18, y: 23, width: badgeWidth - 36, height: 20))
        marker.addSubview(badge); next.contentView = marker
        panel = next; next.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self, weak next] in
            guard let self, let next, self.panel === next else { return }
            self.hide()
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        return next.isVisible
    }

    func hide() {
        dismissal?.cancel(); dismissal = nil
        panel?.orderOut(nil); panel?.close(); panel = nil
    }
}
