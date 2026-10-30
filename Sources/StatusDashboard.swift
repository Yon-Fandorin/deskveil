import AppKit

private final class DashboardFooterButton: NSButton {
    enum Style { case settings, version, quit }
    let style: Style
    private var hovering = false
    private var hoverArea: NSTrackingArea?
    private var textTint = NSColor.secondaryLabelColor

    init(style: Style, title: String, target: AnyObject, action: Selector) {
        self.style = style
        super.init(frame: .zero)
        self.target = target; self.action = action
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        alignment = .center
        imagePosition = .imageLeading
        imageHugsTitle = true
        let textFont = style == .version
            ? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            : NSFont.systemFont(ofSize: 11, weight: .medium)
        font = textFont
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: textFont, .foregroundColor: NSColor.secondaryLabelColor
        ])
        if style == .settings {
            image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        }
        contentTintColor = .secondaryLabelColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = isEnabled && (hovering || isHighlighted)
        let accent: NSColor = style == .quit ? .systemRed : .controlAccentColor
        let tint: NSColor = highlighted ? accent : .secondaryLabelColor
        if contentTintColor != tint { contentTintColor = tint }
        if textTint != tint {
            textTint = tint
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 11), .foregroundColor: tint
            ])
        }
        if highlighted && style != .version {
            accent.withAlphaComponent(isHighlighted ? 0.15 : 0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
        super.draw(dirtyRect)
    }
}

/// AppKit owns this root view's frame, including the popover arrow and glass margins.
/// Only the inner content is laid out in the safe area; the surface fills the shell.
private final class DashboardPopoverRoot: DashboardSurface {
    let content = NSView()

    override init(inset: Bool = false) {
        super.init(inset: inset)
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let safeFrame = safeAreaRect
        let contentFrame = safeFrame.isEmpty ? bounds : safeFrame
        if content.frame != contentFrame { content.frame = contentFrame }
    }
}

/// The status item opens this panel directly so the dashboard is always visible.
final class StatusDashboard: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let dashboard: MenuDashboard
    private let background = DashboardPopoverRoot()
    private let footerDivider = NSBox()
    private var actionViews: [NSView] = []
    private var controls: [String: NSView] = [:]
    private var menuItems: [String: NSMenuItem] = [:]
    private var primary: NSButton?
    private var countdown: NSTextField?
    private weak var anchor: NSView?
    private let dismissesOutside: Bool
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    var isShown: Bool { popover.isShown }
    var view: NSView { background }

    init(dashboard: MenuDashboard, behavior: NSPopover.Behavior = .transient) {
        self.dashboard = dashboard
        dismissesOutside = behavior != .applicationDefined
        super.init()
        background.content.addSubview(dashboard)
        footerDivider.boxType = .separator
        background.content.addSubview(footerDivider)
        let controller = NSViewController()
        controller.view = background
        popover.contentViewController = controller
        if #available(macOS 14.0, *) { popover.hasFullSizeContent = true }
        popover.delegate = self
        popover.behavior = behavior
        popover.animates = false
    }
    deinit { stopDismissalMonitoring() }

    private func startDismissalMonitoring() {
        guard dismissesOutside, localMouseMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMouseDown(event)
            return event // The original click still reaches its destination.
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in self?.close() }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.close() }
    }
    private func stopDismissalMonitoring() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        localMouseMonitor = nil; globalMouseMonitor = nil; resignObserver = nil
    }

    /// Shared by the local monitor and isolated native event-routing checks.
    func handleMouseDown(_ event: NSEvent) {
        guard isShown, [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) else { return }
        if event.window === background.window { return }
        // Let the status item's own action toggle the open popover exactly once.
        if let anchor, event.window === anchor.window,
           anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return }
        close()
    }

    func updateMenu(_ menu: NSMenu) {
        var activeIDs: Set<String> = []
        menuItems.removeAll()
        for item in menu.items {
            guard let id = item.identifier?.rawValue else { continue }
            if id == "quick-countdown" {
                let field: NSTextField
                if let existing = controls[id] as? NSTextField { field = existing }
                else {
                    field = NSTextField(labelWithString: item.title)
                    field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
                    field.textColor = .secondaryLabelColor
                    background.content.addSubview(field)
                    controls[id] = field
                }
                field.stringValue = item.title
                countdown = field
                activeIDs.insert(id)
                continue
            }
            guard ["quick-toggle", "quick-settings", "quick-about", "quick-quit"].contains(id) else { continue }
            let button: NSButton
            if let existing = controls[id] as? NSButton {
                button = existing
            } else if id == "quick-toggle" {
                button = NSButton(title: item.title,
                                  target: self, action: #selector(chooseAction(_:)))
                button.font = .systemFont(ofSize: 12, weight: .medium)
                button.imagePosition = .imageLeading
                button.imageHugsTitle = true
                button.bezelStyle = .rounded
                button.controlSize = .large
                button.bezelColor = .controlAccentColor
                button.image = DeskVeilBrand.mark(size: 16)
                button.toolTip = item.toolTip
                primary = button
            } else {
                let style: DashboardFooterButton.Style
                let title: String
                switch id {
                case "quick-settings": style = .settings; title = L10n.text("설정")
                case "quick-about":
                    style = .version
                    title = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "v\($0)" } ?? L10n.text("개발 버전")
                default: style = .quit; title = L10n.text("종료")
                }
                button = DashboardFooterButton(style: style, title: title, target: self, action: #selector(chooseAction(_:)))
                switch style {
                case .settings:
                    button.toolTip = L10n.text("DeskVeil 설정 열기")
                    button.setAccessibilityLabel(L10n.text("DeskVeil 설정"))
                case .version:
                    button.toolTip = L10n.text("DeskVeil 정보 · %@", String(describing: title))
                    button.setAccessibilityLabel(L10n.text("DeskVeil 정보, 버전 %@", String(describing: title)))
                case .quit:
                    button.toolTip = L10n.text("화면 설정을 복원하고 DeskVeil 종료")
                    button.setAccessibilityLabel(L10n.text("DeskVeil 종료"))
                }
            }
            if id == "quick-toggle" {
                button.title = item.title
                button.toolTip = item.toolTip
                primary = button
            }
            button.isEnabled = item.isEnabled && item.action != nil
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.setAccessibilityIdentifier(id)
            if controls[id] == nil {
                background.content.addSubview(button)
                controls[id] = button
            }
            menuItems[id] = item
            activeIDs.insert(id)
        }
        for id in Array(controls.keys) where !activeIDs.contains(id) {
            controls.removeValue(forKey: id)?.removeFromSuperview()
        }
        primary = controls["quick-toggle"] as? NSButton
        countdown = controls["quick-countdown"] as? NSTextField
        actionViews = Array(controls.values)
        resize()
    }

    func resize() {
        let width = MenuDashboard.panelWidth
        let actionsHeight: CGFloat = countdown == nil ? 106 : 126
        let height = dashboard.frame.height + actionsHeight
        let insets = background.safeAreaInsets
        let size = NSSize(width: width + insets.left + insets.right,
                          height: height + insets.top + insets.bottom)
        // Resetting frame.origin here moves the content into AppKit's chrome on
        // the next one-second refresh. AppKit alone positions the root view.
        if !popover.isShown { background.setFrameSize(size) }
        dashboard.setFrameOrigin(NSPoint(x: 0, y: actionsHeight))
        primary?.frame = NSRect(x: 18, y: 58, width: width - 36, height: 38)
        countdown?.frame = NSRect(x: 20, y: 102, width: width - 40, height: 16)
        footerDivider.frame = NSRect(x: 18, y: 48, width: width - 36, height: 1)
        for button in actionViews.compactMap({ $0 as? DashboardFooterButton }) {
            switch button.style {
            case .settings: button.frame = NSRect(x: 14, y: 12, width: 72, height: 28)
            case .version:
                let size = button.intrinsicContentSize
                let versionWidth = min(140, max(66, size.width + 8))
                button.frame = NSRect(x: (width - versionWidth) / 2, y: 12, width: versionWidth, height: 28)
            case .quit: button.frame = NSRect(x: width - 65, y: 12, width: 46, height: 28)
            }
        }
        if popover.contentSize != size { popover.contentSize = size }
        background.needsLayout = true
        background.layoutSubtreeIfNeeded()
    }

    var layoutSnapshot: [String: Any] {
        ["rootFrame": NSStringFromRect(background.frame),
         "contentFrame": NSStringFromRect(background.content.frame),
         "safeFrame": NSStringFromRect(background.safeAreaRect),
         "dashboardFrame": NSStringFromRect(dashboard.frame),
         "primaryFrame": NSStringFromRect(primary?.frame ?? .zero),
         "footerFrame": NSStringFromRect(footerDivider.frame),
         "contentSize": NSStringFromSize(popover.contentSize),
         "shown": popover.isShown,
         "dismissalMonitoring": localMouseMonitor != nil && globalMouseMonitor != nil && resignObserver != nil,
         "actionControls": controls.mapValues { String(describing: ObjectIdentifier($0)) },
         "actionFrames": controls.mapValues { NSStringFromRect($0.frame) },
         "focusedControl": (background.window?.firstResponder as? NSView)?.accessibilityIdentifier() ?? "",
         "interaction": dashboard.interactionSnapshot]
    }

    @discardableResult func focusForAudit(_ identifier: String) -> Bool {
        func find(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == identifier { return view }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        guard let control = find(background), let window = background.window else { return false }
        return window.makeFirstResponder(control) && window.firstResponder === control
    }

    func toggle(relativeTo button: NSView) {
        if isShown { popover.performClose(nil); return }
        anchor = button
        resize()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        resize()
    }
    func popoverDidShow(_ notification: Notification) { resize(); startDismissalMonitoring() }
    func popoverDidClose(_ notification: Notification) { stopDismissalMonitoring(); anchor = nil }
    func close() { stopDismissalMonitoring(); popover.performClose(nil) }
    @objc private func chooseAction(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let item = menuItems[id] else { return }
        close()
        if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
    }
}
