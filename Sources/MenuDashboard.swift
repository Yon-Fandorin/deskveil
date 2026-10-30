import AppKit

struct MenuDashboardState {
    var displays: [DisplayStatus]?
    var locked: Bool
    var awake: Bool
    var dimming: Bool
    var issue: String?
    var inputAvailable = true
    var inputBlocking: Bool? = nil
    var awakeEnabled = false
    var displayControlsEnabled = false
    var offDisplays: Set<String> = []
    var pendingDisplays: Set<String> = []
    var displayIssues: [String: String] = [:]
    var updateStatus: String? = nil
    enum InputStatus: Equatable { case blocked, released, unavailable, interrupted }
    var inputStatus: InputStatus {
        if locked || inputBlocking == true { return inputAvailable && (inputBlocking ?? locked) ? .blocked : .interrupted }
        return inputAvailable ? .released : .unavailable
    }
    var inputLabel: String {
        switch inputStatus {
        case .blocked: return L10n.text("입력 차단 중")
        case .released: return L10n.text("입력 차단 안 함")
        case .unavailable: return L10n.text("입력 차단 사용 불가")
        case .interrupted: return L10n.text("입력 차단 중단")
        }
    }
    var awakeLabel: String {
        if awake { return L10n.text("잠자기 방지 중") }
        if !awakeEnabled { return L10n.text("잠자기 방지 사용 안 함") }
        return locked ? L10n.text("잠자기 방지 중단") : L10n.text("잠자기 방지 대기")
    }

}

/// Opaque native surfaces avoid stacking a second blur inside the system popover.
class DashboardSurface: NSView {
    var inset = false
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let color: NSColor = inset
                ? (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.955, alpha: 1))
                : (dark ? NSColor(white: 0.105, alpha: 1) : .white)
            layer?.backgroundColor = color.cgColor
            layer?.cornerRadius = inset ? 12 : 0
        }
    }
    init(inset: Bool = false) {
        self.inset = inset
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A momentary action: colour shows the observed output, never an optimistic toggle.
private final class DisplayPowerButton: NSButton {
    private var outputOn: Bool
    private var pending: Bool

    init(outputOn: Bool, pending: Bool, target: AnyObject, action: Selector) {
        self.outputOn = outputOn; self.pending = pending
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        self.target = target; self.action = action
        title = ""
        imagePosition = .imageOnly
        isBordered = false
        setButtonType(.momentaryChange)
        image = NSImage(systemSymbolName: pending ? "hourglass" : "power", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(outputOn: Bool, pending: Bool) {
        self.outputOn = outputOn
        if self.pending != pending {
            self.pending = pending
            image = NSImage(systemSymbolName: pending ? "hourglass" : "power", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let colour: NSColor = pending ? .systemOrange : (outputOn ? .systemGreen : .secondaryLabelColor)
        let tint: NSColor = isEnabled || pending ? colour : .tertiaryLabelColor
        if contentTintColor != tint { contentTintColor = tint }
        let alpha: CGFloat = isHighlighted ? 0.23 : (isEnabled || pending ? 0.12 : 0.06)
        colour.withAlphaComponent(alpha).setFill()
        let diameter = max(0, min(bounds.width, bounds.height) - 2)
        let circle = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                            width: diameter, height: diameter)
        NSBezierPath(ovalIn: circle).fill()
        super.draw(dirtyRect)
    }
}

private final class DashboardLevel: NSView {
    private weak var valueLabel: NSTextField?
    private var displayedPercent: Double?
    // Visual interpolation only: never a fallback measurement or accessibility value.
    private var lastPresentationPercent: Double?
    private var targetPercent: Int?
    private var animation: Timer?
    init(valueLabel: NSTextField) {
        self.valueLabel = valueLabel
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityValue(L10n.text("확인 불가"))
        valueLabel.stringValue = "—"
        heightAnchor.constraint(equalToConstant: 5).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { animation?.invalidate() }

    var animationSnapshot: [String: Any] {
        ["target": targetPercent.map { $0 as Any } ?? NSNull(),
         "presentation": displayedPercent.map { $0 as Any } ?? NSNull(),
         "animating": animation != nil, "text": valueLabel?.stringValue ?? ""]
    }
    func update(_ percent: Int?) {
        guard targetPercent != percent else { return }
        animation?.invalidate(); animation = nil
        targetPercent = percent
        let accessibleValue = percent.map { "\($0)%" } ?? L10n.text("확인 불가")
        setAccessibilityValue(accessibleValue)
        valueLabel?.setAccessibilityValue(accessibleValue)
        guard let percent else { render(nil); return }
        guard let from = displayedPercent ?? lastPresentationPercent, from != Double(percent), window?.isVisible == true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { render(Double(percent)); return }
        render(from)
        let started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / 0.28)
            if progress >= 1 || self.window?.isVisible != true || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self.finishAnimation(); return
            }
            let eased = progress * progress * (3 - 2 * progress)
            self.render(from + (Double(percent) - from) * eased)
        }
        animation = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishAnimation() }
        super.viewWillMove(toWindow: newWindow)
    }
    private func finishAnimation() {
        animation?.invalidate(); animation = nil
        render(targetPercent.map(Double.init))
    }
    private func render(_ percent: Double?) {
        displayedPercent = percent
        if let percent { lastPresentationPercent = percent }
        valueLabel?.stringValue = percent.map { "\(Int($0.rounded()))%" } ?? "—"
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2.5, yRadius: 2.5).fill()
        if let displayedPercent, displayedPercent > 0 {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * CGFloat(displayedPercent / 100), height: bounds.height),
                         xRadius: 2.5, yRadius: 2.5).fill()
        }
    }
}

/// The document has its own origin. Pinning its top to the clip view's top
/// makes Auto Layout move the document with the scrolling bounds instead.
private final class DashboardDisplayDocument: NSView {
    private let list: NSStackView
    override var isFlipped: Bool { true }

    init(list: NSStackView, width: CGFloat) {
        self.list = list
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        // Width comes from the clip bounds directly. A width autoresizing mask
        // would add the clip's initial 0→width delta to our initial width.
        autoresizingMask = []
        list.translatesAutoresizingMaskIntoConstraints = true
        addSubview(list)
        fitContent()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func fitContent() {
        let width = (superview as? NSClipView)?.bounds.width ?? bounds.width
        guard width > 0 else { return }
        let initial = NSRect(x: 0, y: 0, width: width, height: list.fittingSize.height)
        if list.frame != initial { list.frame = initial }
        list.layoutSubtreeIfNeeded()
        let height = list.fittingSize.height
        let fitted = NSRect(x: 0, y: 0, width: width, height: height)
        if list.frame != fitted { list.frame = fitted }
        let size = NSSize(width: width, height: max(height, superview?.bounds.height ?? 0))
        if frame.size != size { setFrameSize(size) }
    }
    override func layout() { super.layout(); fitContent() }
}

private final class DashboardDisplayScrollView: NSScrollView {
    override func tile() {
        super.tile()
        (documentView as? DashboardDisplayDocument)?.fitContent()
    }
}

private final class DisplayIdentifyButton: NSButton {
    private let content: NSView
    init(content: NSView, target: AnyObject, action: Selector) {
        self.content = content
        super.init(frame: .zero)
        self.target = target; self.action = action
        title = ""; isBordered = false; setButtonType(.momentaryChange)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { content.fittingSize }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
}

final class MenuDashboard: NSView, NSGestureRecognizerDelegate {
    var onDisplayPower: ((DisplayStatus, Bool) -> Void)?
    var onDisplayIdentify: ((DisplayStatus) -> Void)?
    private var displayActions: [ObjectIdentifier: (DisplayStatus, Bool)] = [:]
    private var identifyActions: [ObjectIdentifier: DisplayStatus] = [:]
    static let panelWidth: CGFloat = 360
    private var lastState: MenuDashboardState?
    private let content = NSStackView()
    private var displayKeys: [String] = []
    private var displayCard: NSView?
    private var displayRowUpdates: [String: (DisplayStatus, MenuDashboardState) -> Void] = [:]
    private var displayRowViews: [String: NSView] = [:]
    private var displayScroll: NSScrollView?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 100))
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ state: MenuDashboardState) {
        if let last = lastState, last.displays == state.displays, last.locked == state.locked,
           last.awake == state.awake, last.dimming == state.dimming, last.issue == state.issue,
           last.inputAvailable == state.inputAvailable, last.inputBlocking == state.inputBlocking,
           last.awakeEnabled == state.awakeEnabled,
           last.displayControlsEnabled == state.displayControlsEnabled, last.offDisplays == state.offDisplays,
           last.pendingDisplays == state.pendingDisplays, last.displayIssues == state.displayIssues,
           last.updateStatus == state.updateStatus { return }
        lastState = state
        displayActions.removeAll()
        identifyActions.removeAll()
        // Keep the display subtree attached while refreshing labels around it.
        // Removing it would discard scrolling and keyboard/accessibility focus.
        content.arrangedSubviews.filter { $0 !== displayCard }.forEach {
            content.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        let logo = NSImageView(image: DeskVeilBrand.mark(size: 25))
        logo.contentTintColor = .controlAccentColor
        let brand = horizontal([logo, label("DeskVeil", size: 15, weight: .semibold)], spacing: 9)
        let count = state.displays.map { L10n.text("%@대 연결", String(describing: $0.count)) } ?? L10n.text("확인 필요")
        let heading = row(brand, label(count, size: 11, secondary: true))
        heading.translatesAutoresizingMaskIntoConstraints = false
        content.insertArrangedSubview(heading, at: 0)
        heading.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        if let displays = state.displays, !displays.isEmpty {
            let keys = displays.map { $0.identity ?? "display-id-\($0.id)" }
            if keys != displayKeys || displayCard == nil {
                if let displayCard { content.removeArrangedSubview(displayCard); displayCard.removeFromSuperview() }
                displayKeys = keys; displayRowUpdates.removeAll(); displayRowViews.removeAll(); displayScroll = nil
                let list = vertical([], spacing: 0)
                for (index, display) in displays.enumerated() {
                    if index > 0 { append(inset(divider(), horizontal: 12, vertical: 0), to: list) }
                    let view = inset(displayRow(display, state: state), horizontal: 12, vertical: 11)
                    displayRowViews[display.identity ?? "display-id-\(display.id)"] = view
                    append(view, to: list)
                }
                if displays.count > 3 {
                    let scroll = DashboardDisplayScrollView()
                    scroll.hasVerticalScroller = true; scroll.drawsBackground = false
                    scroll.documentView = DashboardDisplayDocument(list: list, width: Self.panelWidth - 36)
                    scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
                    displayScroll = scroll
                    displayCard = card(scroll)
                } else { displayCard = card(list) }
                add(displayCard!)
            } else {
                for display in displays {
                    displayRowUpdates[display.identity ?? "display-id-\(display.id)"]?(display, state)
                }
            }
        } else {
            if let displayCard { content.removeArrangedSubview(displayCard); displayCard.removeFromSuperview() }
            displayCard = nil; displayKeys = []; displayRowUpdates.removeAll(); displayRowViews.removeAll(); displayScroll = nil
            let message = state.displays == nil ? L10n.text("디스플레이 상태를 읽지 못했습니다.") : L10n.text("연결된 디스플레이가 없습니다.")
            add(card(inset(label(message, size: 12, secondary: true), horizontal: 12, vertical: 16)))
        }
        let blocking = state.inputStatus == .blocked
        let inputWarning = state.inputStatus == .unavailable || state.inputStatus == .interrupted
        let input = horizontal([symbol(inputWarning ? "exclamationmark.triangle" : (blocking ? "lock.fill" : "lock.open"), size: 12,
                                       color: inputWarning ? .systemOrange : (blocking ? .controlAccentColor : .secondaryLabelColor)),
                                label(state.inputLabel, size: 11, secondary: !blocking, wrap: true)], spacing: 6)
        let awake = horizontal([symbol("moon.zzz", size: 13, color: state.awake ? .controlAccentColor : .secondaryLabelColor),
                                label(state.awakeLabel, size: 11, secondary: !state.awake, wrap: true)], spacing: 6)
        input.toolTip = L10n.text("입력 차단 세션과 입력 감시 연결 상태를 확인합니다.")
        awake.toolTip = L10n.text("설정값과 실제 잠자기 방지 요청의 활성 상태를 구분해 표시합니다.")
        add(row(input, awake))
        if let issue = state.issue { add(label(issue, size: 11, color: .systemOrange, wrap: true)) }
        if let status = state.updateStatus { add(label(status, size: 11, secondary: true, wrap: true)) }
        layoutSubtreeIfNeeded()
        (displayScroll?.documentView as? DashboardDisplayDocument)?.fitContent()
        frame.size.height = content.fittingSize.height + 26
    }

    private func displayRow(_ display: DisplayStatus, state: MenuDashboardState) -> NSView {
        let detail = display.builtIn ? L10n.text("내장 디스플레이") : L10n.text("외장 / 가상 디스플레이")
        let subtitle = detail + (display.brightnessPercent == nil ? L10n.text(" · 밝기 확인 불가") : "")
        let name = label(display.name, size: 12, weight: .medium)
        let subtitleLabel = label(subtitle, size: 10, secondary: true)
        let identityContent = horizontal([symbol(display.builtIn ? "laptopcomputer" : "display", size: 22, color: .secondaryLabelColor),
            vertical([name, subtitleLabel], spacing: 3)], spacing: 9)
        let identity = DisplayIdentifyButton(content: identityContent, target: self, action: #selector(identifyDisplay(_:)))
        let power = DisplayPowerButton(outputOn: true, pending: false, target: self,
                                       action: #selector(displayPowerPressed(_:)))
        let result = vertical([row(identity, power)], spacing: 9)
        let click = NSClickGestureRecognizer(target: self, action: #selector(identifyDisplay(_:)))
        click.delegate = self
        click.delaysPrimaryMouseButtonEvents = false
        result.addGestureRecognizer(click)
        let value = label("", size: 11, secondary: true)
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        value.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let level = DashboardLevel(valueLabel: value)
        let brightness = horizontal([level, value], spacing: 10)
        brightness.heightAnchor.constraint(equalToConstant: 14).isActive = true
        append(brightness, to: result)
        let issueLabel = label("", size: 10, color: .systemOrange, wrap: true)
        let update: (DisplayStatus, MenuDashboardState) -> Void = { [weak self] display, state in
            guard let self else { return }
            name.stringValue = display.name
            subtitleLabel.stringValue = (display.builtIn ? L10n.text("내장 디스플레이") : L10n.text("외장 / 가상 디스플레이"))
                + (display.brightnessPercent == nil ? L10n.text(" · 밝기 확인 불가") : "")
            let key = display.identity ?? ""
            let pending = state.pendingDisplays.contains(key)
            let off = state.offDisplays.contains(key)
            let identifiable = state.displayControlsEnabled && display.identity != nil && !pending && !off
                && !display.subdued && display.brightnessPercent != 0
            identity.isEnabled = identifiable; click.isEnabled = identifiable
            name.textColor = identifiable ? .labelColor : .secondaryLabelColor
            identity.setAccessibilityIdentifier("display-identify-\(display.id)")
            identity.setAccessibilityLabel(L10n.text("%@ 화면 식별", String(describing: display.name)))
            identity.toolTip = identifiable ? L10n.text("클릭하면 이 화면에 식별 번호를 잠깐 표시합니다.")
                : L10n.text("켜져 있는 화면에서 식별 번호를 표시할 수 있습니다.")
            self.identifyActions[ObjectIdentifier(identity)] = display
            self.identifyActions[ObjectIdentifier(click)] = display
            let outputOn = !off && !display.subdued && (display.brightnessPercent.map { $0 > 0 } ?? true)
            power.update(outputOn: outputOn, pending: pending)
            power.isEnabled = state.displayControlsEnabled && display.identity != nil && !pending && (off || (display.active && !display.asleep))
            power.setAccessibilityLabel(L10n.text("%@ 화면 %@", String(describing: display.name), String(describing: off ? L10n.text("켜기") : L10n.text("끄기"))))
            power.setAccessibilityValue(pending ? L10n.text("처리 중") : display.label)
            power.setAccessibilityIdentifier("display-power-\(display.id)")
            power.tag = Int(display.id)
            self.displayActions[ObjectIdentifier(power)] = (display, !off)
            if pending {
                power.toolTip = L10n.text("화면 변경을 처리하고 있습니다.")
            } else if !state.displayControlsEnabled {
                power.toolTip = L10n.text("전체 입력 차단과 화면 전환이 끝난 뒤 개별 화면을 조작할 수 있습니다.")
            } else if display.identity == nil {
                power.toolTip = L10n.text("이 화면을 식별할 수 없어 개별 제어를 사용할 수 없습니다.")
            } else if display.asleep && !off {
                power.toolTip = L10n.text("macOS에서 잠자기 중인 화면입니다.")
            } else {
                power.toolTip = (off ? L10n.text("화면 켜기 · 원래 밝기와 색상으로 복원") : L10n.text("화면 끄기 · 이 화면만 어둡게"))
                    + L10n.text("\n물리적 전원은 바꾸지 않습니다.")
            }
            if let hint = power.toolTip { power.toolTip = L10n.text("현재 상태: %@\n", String(describing: display.label)) + hint }
            level.update(display.brightnessPercent)
            level.setAccessibilityLabel(L10n.text("%@ 밝기", String(describing: display.name)))
            level.setAccessibilityIdentifier("display-brightness-\(display.id)")
            if let issue = state.displayIssues[key] {
                issueLabel.stringValue = issue
                if issueLabel.superview == nil { self.append(issueLabel, to: result) }
            } else if issueLabel.superview != nil {
                result.removeArrangedSubview(issueLabel); issueLabel.removeFromSuperview()
            }
        }
        displayRowUpdates[display.identity ?? "display-id-\(display.id)"] = update
        update(display, state)
        return result
    }

    /// Audit data is separate from the visible accessibility labels.
    var interactionSnapshot: [String: Any] {
        var controls: [String: String] = [:]
        var powerFrames: [String: String] = [:]
        var brightness: [String: Any] = [:]
        func inspect(_ view: NSView) {
            if let level = view as? DashboardLevel {
                brightness[level.accessibilityIdentifier()] = level.animationSnapshot
            }
            if let button = view as? NSButton {
                let identifier = button.accessibilityIdentifier()
                if identifier.hasPrefix("display-power-") { controls[identifier] = String(describing: ObjectIdentifier(button)) }
                if let document = displayScroll?.documentView, identifier.hasPrefix("display-power-") {
                    powerFrames[identifier] = NSStringFromRect(button.convert(button.bounds, to: document))
                }
            }
            view.subviews.forEach(inspect)
        }
        inspect(self)
        var snapshot: [String: Any] = ["displayControls": controls, "brightness": brightness,
            "scrollOrigin": NSStringFromPoint(displayScroll?.contentView.bounds.origin ?? .zero)]
        if let scroll = displayScroll, let document = scroll.documentView {
            snapshot["documentFrame"] = NSStringFromRect(document.frame)
            snapshot["documentBounds"] = NSStringFromRect(document.bounds)
            snapshot["visibleRect"] = NSStringFromRect(scroll.documentVisibleRect)
            snapshot["rowFrames"] = displayRowViews.mapValues { NSStringFromRect($0.convert($0.bounds, to: document)) }
            snapshot["powerFrames"] = powerFrames
        }
        return snapshot
    }

    func scrollForAudit() {
        guard let scroll = displayScroll, let document = scroll.documentView else { return }
        let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum / 2))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func displayPowerPressed(_ sender: NSButton) {
        guard sender.isEnabled, let (display, off) = displayActions[ObjectIdentifier(sender)] else { return }
        onDisplayPower?(display, off)
    }

    @objc private func identifyDisplay(_ sender: AnyObject) {
        if let button = sender as? NSButton, !button.isEnabled { return }
        if let gesture = sender as? NSGestureRecognizer, !gesture.isEnabled { return }
        guard let display = identifyActions[ObjectIdentifier(sender)] else { return }
        onDisplayIdentify?(display)
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown, let view = gestureRecognizer.view else { return false }
        // Native buttons own their clicks; row identification must never also
        // run when the user toggles power or activates the accessible label.
        func overButton(_ child: NSView) -> Bool {
            if let button = child as? NSButton,
               button.bounds.contains(button.convert(event.locationInWindow, from: nil)) { return true }
            return child.subviews.contains(where: overButton)
        }
        return !overButton(view)
    }

    private func label(_ title: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       secondary: Bool = false, color: NSColor? = nil, wrap: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.maximumNumberOfLines = wrap ? 0 : 1
        field.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color ?? (secondary ? .secondaryLabelColor : .labelColor)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    private func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        view.contentTintColor = color
        view.widthAnchor.constraint(equalToConstant: size + 2).isActive = true
        view.heightAnchor.constraint(equalToConstant: size + 2).isActive = true
        return view
    }
    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        stack.detachesHiddenViews = false
        for view in views { view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true }
        return stack
    }
    private func horizontal(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = spacing
        stack.detachesHiddenViews = false
        return stack
    }
    private func row(_ left: NSView, _ right: NSView) -> NSView {
        let row = NSView()
        for view in [left, right] { view.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(view) }
        left.setContentHuggingPriority(.init(251), for: .horizontal)
        right.setContentHuggingPriority(.init(252), for: .horizontal)
        left.setContentCompressionResistancePriority(.init(749), for: .horizontal)
        right.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            right.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            right.widthAnchor.constraint(greaterThanOrEqualToConstant: right.fittingSize.width + 6),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -8),
            left.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            right.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            left.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor),
            right.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor),
            left.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
            right.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor)
        ])
        return row
    }
    private func inset(_ view: NSView, horizontal: CGFloat, vertical: CGFloat) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontal),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontal),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: vertical),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vertical)
        ])
        return container
    }
    private func card(_ view: NSView) -> NSView {
        let surface = DashboardSurface(inset: true)
        view.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: surface.leadingAnchor), view.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            view.topAnchor.constraint(equalTo: surface.topAnchor), view.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        return surface
    }
    private func divider() -> NSView { let line = NSBox(); line.boxType = .separator; return line }
    private func append(_ view: NSView, to stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func add(_ view: NSView) { append(view, to: content) }
}
