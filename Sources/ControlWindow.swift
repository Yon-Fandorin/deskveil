import AppKit

/// Selection changes the background, never the icon or label positions.
private final class SidebarButtonCell: NSButtonCell {
    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        if state == .on || isHighlighted {
            let dark = controlView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let opacity: CGFloat = state == .on ? (dark ? 0.075 : 0.045) : (dark ? 0.04 : 0.025)
            let surface = NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7)
            NSColor.labelColor.withAlphaComponent(opacity).setFill()
            surface.fill()
            if state == .on {
                NSColor.labelColor.withAlphaComponent(dark ? 0.08 : 0.05).setStroke()
                let edge = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 6.5, yRadius: 6.5)
                edge.lineWidth = 0.5
                edge.stroke()
            }
        }
        let color: NSColor = state == .on ? .labelColor : .secondaryLabelColor
        let iconFrame = NSRect(x: frame.minX + 10, y: frame.midY - 9, width: 18, height: 18)
        let icon = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
        if let icon {
            let scale = min(iconFrame.width / icon.size.width, iconFrame.height / icon.size.height)
            let size = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
            let rect = NSRect(x: iconFrame.midX - size.width / 2, y: iconFrame.midY - size.height / 2,
                              width: size.width, height: size.height)
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: nil)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: color
        ]
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(in: NSRect(x: frame.minX + 38, y: frame.midY - height / 2,
                                           width: frame.width - 48, height: height), withAttributes: attributes)
    }
}

/// A soft accent around the brand, drawn over the native sidebar material.
private final class SidebarGlowView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let accent = NSColor.systemBlue
        let center = NSPoint(x: 42, y: bounds.height - 66)
        let ambient = NSGradient(starting: accent.withAlphaComponent(dark ? 0.07 : 0.045),
                                 ending: accent.withAlphaComponent(0))
        ambient?.draw(fromCenter: center, radius: 0, toCenter: center, radius: 210, options: [])
        let glow = NSGradient(colorsAndLocations:
            (accent.withAlphaComponent(dark ? 0.15 : 0.095), 0),
            (accent.withAlphaComponent(dark ? 0.045 : 0.025), 0.45),
            (accent.withAlphaComponent(0), 1))
        glow?.draw(fromCenter: center, radius: 0, toCenter: center, radius: 110, options: [])
    }
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class SettingsSectionHeader: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor.labelColor.withAlphaComponent(dark ? 0.055 : 0.025).setFill()
        bounds.fill()
    }
}

struct ControlWindowState {
    let locked: Bool
    let ready: Bool
    let title: String
    let dim: Bool
    let awake: Bool
    let shortcut: KeyboardShortcut
    let emergency: KeyboardShortcut
    let fade: TimeInterval
    let lockOnUnlock: Bool
    let errorSound: Bool
    let powerStatus: String
    let idleStatus: String
    let physicalEvents: Int
    let softwareEvents: Int
    let accessibility: Bool
    let issue: String?
    var lidEnabled = false
    var lidOnBattery = false
    var batteryReservePercent = BatteryReserve.defaultPercent
    var lidStatus = L10n.text("설정 전")
    var lidDurationSeconds = 0
    var lidInstalled = false
    var lidNeedsSetup = true
    var lidBusy = false
    var lidSetupTitle = L10n.text("보조 도구 설치…")
    var lidHasLog = false
    var lidHasService = false
    var updating = false
    var privacyShielded = false
    var languageChangeAllowed = true
}

/// Native presentation only. Session, permission, and preference ownership stays in AppDelegate.
final class ControlWindow: NSWindowController, NSTextFieldDelegate {
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusSubtitle = NSTextField(labelWithString: "")
    private let statusImage = NSImageView()
    private let trial = NSButton(title: L10n.text("테스트"), target: nil, action: nil)
    private let dim = NSSwitch()
    private let awake = NSSwitch()
    private let lid = NSSwitch()
    private let lidBattery = NSSwitch()
    private let batteryReserve = SteppedSetting(title: L10n.text("배터리 종료 기준"),
        choices: BatteryReserve.choices.map { "\($0)%" }, id: "battery-reserve")
    private let lidDurations = SteppedSetting(title: L10n.text("덮개 유지 시간"),
        choices: LidDuration.choices.map { $0.title } + [L10n.text("직접 설정")], id: "lid-duration")
    private let lidHours = NSTextField(string: "24")
    private var lidCustomRow: NSStackView!
    private var customDurationSelected = false
    private var lidSetup: NSButton!
    private var lidRemove: NSButton!
    private var lidLog: NSButton!
    private var lidActions: NSStackView!
    private let lidPermissionValue = NSTextField(labelWithString: "")
    private let lidPermissionDescription = NSTextField(wrappingLabelWithString: "")
    private let lidPermissionImage = NSImageView()
    private let lockOnUnlock = NSSwitch()
    private let errorSound = NSSwitch()
    private let shortcuts = ShortcutRecorder(label: L10n.text("차단·해제 단축키"))
    private let emergencyShortcut = ShortcutRecorder(label: L10n.text("긴급 해제 단축키"))
    private var resetKeys: NSButton!
    private var currentNormal = KeyboardShortcut.normal
    private var currentEmergency = KeyboardShortcut.emergency
    private let emergencyHint = NSTextField(labelWithString: KeyboardShortcut.emergency.label)
    private let onShortcutChange: (KeyboardShortcut, KeyboardShortcut) -> String?
    private let onShortcutRecording: (Bool) -> Void
    private var fadeValues: [TimeInterval] = [0, 0.15, 0.3, 0.6, 1]
    private let fades = SteppedSetting(title: L10n.text("밝기 전환 시간"),
        choices: [L10n.text("즉시"), L10n.text("0.15초"), L10n.text("0.3초"), L10n.text("0.6초"), L10n.text("1초")], id: "brightness-speed")
    private let language = NSPopUpButton()
    private let applyLanguage = NSButton(title: L10n.text("적용 및 재시작"), target: nil, action: nil)
    private let initialLanguage = AppLanguage.selection()
    private var languageChangeAllowed = false
    private let onLanguageChange: (AppLanguage) -> Void
    private let trials = NSPopUpButton()
    private let issueLabel = NSTextField(wrappingLabelWithString: "")
    private let testHint = NSTextField(wrappingLabelWithString: "")
    private let permissionValue = NSTextField(labelWithString: "")
    private let permissionDescription = NSTextField(wrappingLabelWithString: "")
    private let permissionImage = NSImageView()
    private var repairSection: DisclosureSection!
    private var repairOpen: NSButton!
    private let testLink = NSButton(title: L10n.text("입력 차단 테스트"), target: nil, action: nil)
    private var permissionButtons: [NSButton] = []
    private var permissionActions: NSStackView!
    private var navigation: [NSButton] = []
    private var pages: [NSView] = []
    private var values: [String: NSTextField] = [:]
    private var currentLocked = false
    private var currentReady = false
    enum Pane: Int, CaseIterable {
        case general, work, permissions, diagnostics
        var title: String {
            switch self {
            case .general: return L10n.text("일반")
            case .work: return L10n.text("작업 유지")
            case .permissions: return L10n.text("권한 및 보조 도구")
            case .diagnostics: return L10n.text("테스트 및 진단")
            }
        }
        var symbol: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .work: return "moon.zzz"
            case .permissions: return "hand.raised"
            case .diagnostics: return "checkmark.circle"
            }
        }
    }
    private var currentPane: Pane = .general
    private let onTrial: (TimeInterval) -> Void
    private let onSettings: (Bool, Bool, TimeInterval, Bool) -> Void
    private let onPermissions: () -> Void
    private let onRetry: () -> Void
    private let onRelaunch: () -> Void
    private let onErrorSoundChange: (Bool) -> Void
    private let onLidChange: (Bool) -> Void
    private let onLidBatteryChange: (Bool) -> Void
    private let onBatteryReserveChange: (Int) -> Void
    private let onLidDurationChange: (Int) -> Void
    private let onLidSetup: () -> Void
    private let onLidRemove: () -> Void
    private let onLidLog: () -> Void

    init(onTrial: @escaping (TimeInterval) -> Void,
         onSettings: @escaping (Bool, Bool, TimeInterval, Bool) -> Void,
         onPermissions: @escaping () -> Void, onRetry: @escaping () -> Void,
         onRelaunch: @escaping () -> Void,
         onShortcutChange: @escaping (KeyboardShortcut, KeyboardShortcut) -> String? = { _,_ in nil },
         onShortcutRecording: @escaping (Bool) -> Void = { _ in },
         onLanguageChange: @escaping (AppLanguage) -> Void = { _ in },
         onErrorSoundChange: @escaping (Bool) -> Void = { _ in },
         onLidChange: @escaping (Bool) -> Void = { _ in },
         onLidBatteryChange: @escaping (Bool) -> Void = { _ in },
         onBatteryReserveChange: @escaping (Int) -> Void = { _ in },
         onLidDurationChange: @escaping (Int) -> Void = { _ in },
         onLidSetup: @escaping () -> Void = {},
         onLidRemove: @escaping () -> Void = {},
         onLidLog: @escaping () -> Void = {}) {
        self.onTrial = onTrial; self.onSettings = onSettings
        self.onPermissions = onPermissions; self.onRetry = onRetry; self.onRelaunch = onRelaunch
        self.onLanguageChange = onLanguageChange
        self.onErrorSoundChange = onErrorSoundChange
        self.onLidChange = onLidChange; self.onLidSetup = onLidSetup
        self.onLidBatteryChange = onLidBatteryChange
        self.onBatteryReserveChange = onBatteryReserveChange
        self.onLidDurationChange = onLidDurationChange
        self.onLidRemove = onLidRemove; self.onLidLog = onLidLog
        self.onShortcutChange = onShortcutChange; self.onShortcutRecording = onShortcutRecording
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        var contentRect = NSRect(x: 0, y: 0, width: 760, height: 636)
        if let screen = NSScreen.main {
            let decoration = NSWindow.frameRect(forContentRect: contentRect, styleMask: style).height - contentRect.height
            contentRect.size.height = min(contentRect.height, max(360, screen.visibleFrame.height - decoration))
        }
        let window = NSWindow(contentRect: contentRect,
                              styleMask: style,
                              backing: .buffered, defer: false)
        window.title = L10n.text("DeskVeil 설정")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func text(_ string: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func stack(_ views: [NSView], horizontal: Bool = false, spacing: CGFloat = 8) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = horizontal ? .horizontal : .vertical
        result.alignment = horizontal ? .centerY : .leading
        result.spacing = spacing
        result.detachesHiddenViews = true
        return result
    }

    private func button(_ title: String, action: Selector, prominent: Bool = false) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded
        result.controlSize = .regular
        result.font = .systemFont(ofSize: 13)
        if prominent { result.bezelColor = .controlAccentColor }
        return result
    }

    private func spacer() -> NSView {
        let result = NSView()
        result.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return result
    }

    private func pin(_ view: NSView, to parent: NSView, inset: CGFloat = 0) {
        view.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }

    private func row(_ title: String, subtitle: String? = nil, control: NSView,
                     height: CGFloat = 60, inset: CGFloat = 16) -> NSView {
        let copy = stack([text(title)] + (subtitle.map { [text($0, size: 11, secondary: true)] } ?? []), spacing: 4)
        let result = NSView()
        let content = stack([copy, spacer(), control], horizontal: true, spacing: 16)
        content.translatesAutoresizingMaskIntoConstraints = false
        result.addSubview(content)
        NSLayoutConstraint.activate([
            result.heightAnchor.constraint(equalToConstant: height),
            content.leadingAnchor.constraint(equalTo: result.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: result.trailingAnchor, constant: -inset),
            content.centerYAnchor.constraint(equalTo: result.centerYAnchor),
            copy.widthAnchor.constraint(lessThanOrEqualTo: result.widthAnchor, constant: -160)
        ])
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return result
    }

    private func group(_ rows: [NSView], header: NSView? = nil) -> NSView {
        let box = NSBox()
        box.boxType = .custom; box.titlePosition = .noTitle
        box.borderWidth = 1; box.cornerRadius = 10
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        let content = stack([], spacing: 0)
        content.alignment = .leading
        if let header {
            box.contentView!.wantsLayer = true
            box.contentView!.layer?.cornerRadius = box.cornerRadius
            box.contentView!.layer?.masksToBounds = true
            let divider = contentDivider()
            for view in [header, divider] {
                content.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            }
        }
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = NSBox(); line.boxType = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                row.addSubview(line)
                NSLayoutConstraint.activate([
                    line.heightAnchor.constraint(equalToConstant: 1),
                    line.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                    line.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
                    line.topAnchor.constraint(equalTo: row.topAnchor)
                ])
            }
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        pin(content, to: box.contentView!)
        return box
    }

    private func page(_ title: String, description: String, views: [NSView]) -> NSView {
        let heading = stack([text(title, size: 20, weight: .semibold)] + (description.isEmpty ? [] : [text(description, size: 12, secondary: true)]), spacing: 6)
        let content = stack(views, spacing: 16)
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        let document = SettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let result = NSView()
        for view in [heading, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            result.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: result.leadingAnchor),
            heading.trailingAnchor.constraint(equalTo: result.trailingAnchor),
            heading.topAnchor.constraint(equalTo: result.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: result.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: result.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: result.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 1),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -1),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 1),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ])
        return result
    }

    private func buildUI() {
        guard let root = window?.contentView else { return }
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar; sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 208)
        ])
        let glow = SidebarGlowView()
        pin(glow, to: sidebar)
        let logo = NSImageView(image: DeskVeilBrand.mark(size: 20))
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.contentTintColor = .controlAccentColor
        logo.widthAnchor.constraint(equalToConstant: 20).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let brand = NSView()
        let brandContent = stack([logo, text("DeskVeil", size: 15, weight: .semibold)], horizontal: true, spacing: 8)
        brandContent.translatesAutoresizingMaskIntoConstraints = false
        brand.addSubview(brandContent)
        NSLayoutConstraint.activate([
            brand.widthAnchor.constraint(equalToConstant: 176),
            brand.heightAnchor.constraint(equalToConstant: 24),
            brandContent.leadingAnchor.constraint(equalTo: brand.leadingAnchor, constant: 10),
            brandContent.centerYAnchor.constraint(equalTo: brand.centerYAnchor)
        ])
        let nav = stack([brand], spacing: 16)
        let choices = stack([], spacing: 4)
        for pane in Pane.allCases {
            if pane == .permissions { choices.addArrangedSubview(contentDivider()) }
            let index = pane.rawValue
            let entry = (pane.title, pane.symbol)
            let choice = NSButton()
            choice.cell = SidebarButtonCell(textCell: entry.0)
            choice.title = entry.0
            choice.target = self; choice.action = #selector(selectPane(_:))
            choice.setButtonType(.momentaryChange)
            choice.image = NSImage(systemSymbolName: entry.1, accessibilityDescription: nil)
            choice.imagePosition = .imageLeading
            choice.font = .systemFont(ofSize: 13, weight: .medium)
            choice.isBordered = false
            choice.tag = index
            choice.setAccessibilityLabel(entry.0)
            choice.setAccessibilityIdentifier("settings-pane-\(index)")
            choice.widthAnchor.constraint(equalToConstant: 176).isActive = true
            choice.heightAnchor.constraint(equalToConstant: 34).isActive = true
            choices.addArrangedSubview(choice)
            navigation.append(choice)
        }
        nav.addArrangedSubview(choices)
        nav.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(nav)
        NSLayoutConstraint.activate([
            nav.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            nav.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 48)
        ])
        emergencyHint.font = .systemFont(ofSize: 11, weight: .medium)
        let emergency = stack([text(L10n.text("긴급 해제"), size: 11, secondary: true), emergencyHint], horizontal: true, spacing: 8)
        emergency.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emergency)
        resetKeys = button(L10n.text("단축키 초기화"), action: #selector(resetShortcuts))
        resetKeys.toolTip = L10n.text("차단·해제 키와 긴급 해제 키를 모두 기본값으로 되돌립니다.")
        resetKeys.controlSize = .small
        resetKeys.font = .systemFont(ofSize: 11)
        NSLayoutConstraint.activate([
            emergency.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 24),
            emergency.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        configureControls()
        pages = [generalPage(), workPage(), permissionPage(), diagnosticsPage()]
        issueLabel.font = .systemFont(ofSize: 11)
        issueLabel.textColor = .systemOrange
        issueLabel.maximumNumberOfLines = 3
        issueLabel.isSelectable = true
        issueLabel.setAccessibilityIdentifier("last-issue")
        issueLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(issueLabel)
        NSLayoutConstraint.activate([
            issueLabel.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 24),
            issueLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            issueLabel.bottomAnchor.constraint(equalTo: emergency.topAnchor, constant: -10)
        ])
        for (index, page) in pages.enumerated() {
            page.identifier = NSUserInterfaceItemIdentifier("settings-page-\(index)")
            page.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 24),
                page.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
                page.topAnchor.constraint(equalTo: root.topAnchor, constant: 38),
                page.bottomAnchor.constraint(equalTo: issueLabel.topAnchor, constant: -14)
            ])
        }
        showPane(.general)
    }

    private func configureControls() {
        trial.target = self; trial.action = #selector(trialPressed); trial.bezelStyle = .rounded
        trial.setAccessibilityIdentifier("trial-start")
        for seconds in [15, 60] { trials.addItem(withTitle: L10n.text("%@초", String(describing: seconds))); trials.lastItem?.tag = seconds }
        trials.setAccessibilityIdentifier("trial-duration")
        trials.setAccessibilityLabel(L10n.text("테스트 자동 해제 시간"))
        trials.toolTip = L10n.text("화면을 켜둔 채 입력 차단만 시험합니다. 수동으로 끝내도 macOS 인증을 요청하지 않습니다.")
        dim.target = self; dim.action = #selector(settingsChanged); dim.setAccessibilityIdentifier("dim-screen")
        dim.setAccessibilityLabel(L10n.text("화면 어둡게"))
        dim.toolTip = L10n.text("내장은 밝기를 낮추고, 지원 외장은 밝기와 출력 색상을 함께 낮춰 내용을 검게 가립니다. 화면 연결은 유지하며 해제하면 원래 값으로 복원합니다. 외장 백라이트의 빛은 남을 수 있습니다.")
        awake.target = self; awake.action = #selector(settingsChanged); awake.setAccessibilityIdentifier("keep-awake")
        awake.setAccessibilityLabel(L10n.text("잠자기·자동 잠금 방지"))
        lid.target = self; lid.action = #selector(lidChanged)
        lid.setAccessibilityIdentifier("keep-awake-with-lid-closed")
        lid.setAccessibilityLabel(L10n.text("덮개를 닫아도 계속 실행"))
        lid.toolTip = L10n.text("일반 차단에 적용합니다. 배터리 사용은 아래 옵션에서 선택합니다. 응답 중단·해제 시 잠자기 설정을 복구합니다.")
        lidBattery.target = self; lidBattery.action = #selector(lidBatteryChanged)
        lidBattery.setAccessibilityIdentifier("keep-awake-on-battery")
        lidBattery.setAccessibilityLabel(L10n.text("배터리에서도 계속 실행"))
        lidBattery.toolTip = L10n.text("덮개 유지 중 전원을 분리해도 작업을 계속합니다. 아래에서 선택한 잔량에 도달하거나 잔량을 확인할 수 없으면 종료합니다.")
        batteryReserve.onChange = { [weak self] _ in self?.batteryReserveChanged() }
        lidDurations.onChange = { [weak self] _ in self?.lidDurationChanged() }
        let hoursFormatter = NumberFormatter()
        hoursFormatter.numberStyle = .decimal; hoursFormatter.usesGroupingSeparator = false
        hoursFormatter.allowsFloats = false; hoursFormatter.minimum = 1
        hoursFormatter.maximum = NSNumber(value: LidDuration.maximumHours)
        lidHours.formatter = hoursFormatter; lidHours.delegate = self
        lidHours.alignment = .right
        lidHours.widthAnchor.constraint(equalToConstant: 64).isActive = true
        lidHours.setAccessibilityIdentifier("lid-duration-hours")
        lidHours.setAccessibilityLabel(L10n.text("유지 시간 · 시간 단위"))
        lidHours.toolTip = L10n.text("1~8,760시간을 입력할 수 있습니다. 새 차단을 시작할 때 적용됩니다.")
        lockOnUnlock.target = self; lockOnUnlock.action = #selector(settingsChanged)
        lockOnUnlock.setAccessibilityIdentifier("lock-on-unlock")
        lockOnUnlock.setAccessibilityLabel(L10n.text("해제할 때 macOS 잠금"))
        lockOnUnlock.toolTip = L10n.text("일반 해제에만 적용합니다. 자동 해제 테스트·긴급 해제·오류 복구는 제외됩니다.")
        errorSound.target = self; errorSound.action = #selector(errorSoundChanged)
        errorSound.setAccessibilityIdentifier("error-sound")
        errorSound.setAccessibilityLabel(L10n.text("오류 알림 소리"))
        errorSound.toolTip = L10n.text("macOS 잠금 전환에 실패했을 때 소리를 냅니다. 기본값은 꺼짐입니다.")
        shortcuts.setAccessibilityIdentifier("lock-shortcut")
        emergencyShortcut.setAccessibilityIdentifier("emergency-shortcut")
        for recorder in [shortcuts, emergencyShortcut] {
            recorder.widthAnchor.constraint(equalToConstant: 188).isActive = true
            recorder.onRecording = { [weak self, weak recorder] active in
                guard let self else { return }
                if active {
                    if recorder === self.shortcuts { self.emergencyShortcut.cancel() }
                    else { self.shortcuts.cancel() }
                }
                self.onShortcutRecording(active)
            }
        }
        shortcuts.onCommit = { [weak self] candidate in
            guard let self else { return L10n.text("설정 창을 다시 열어주세요.") }
            return self.onShortcutChange(candidate, self.currentEmergency)
        }
        emergencyShortcut.onCommit = { [weak self] candidate in
            guard let self else { return L10n.text("설정 창을 다시 열어주세요.") }
            return self.onShortcutChange(self.currentNormal, candidate)
        }
        fades.onChange = { [weak self] _ in self?.settingsChanged() }
    }

    private func generalPage() -> NSView {
        language.addItems(withTitles: AppLanguage.allCases.map { $0.title })
        language.selectItem(at: AppLanguage.allCases.firstIndex(of: initialLanguage) ?? 0)
        language.target = self; language.action = #selector(languageSelected)
        language.setAccessibilityIdentifier("interface-language")
        language.setAccessibilityLabel(L10n.text("언어 / Language"))
        applyLanguage.target = self; applyLanguage.action = #selector(applyLanguagePressed)
        applyLanguage.bezelStyle = .rounded
        applyLanguage.toolTip = L10n.text("재시작하면 적용됩니다. 차단·화면 복구 중에는 재시작할 수 없습니다.")
        applyLanguage.setAccessibilityIdentifier("apply-language")
        let languageControls = stack([language, applyLanguage], horizontal: true, spacing: 8)
        return page(Pane.general.title, description: "", views: [
            settingsSection(L10n.text("차단과 해제"), accessory: resetKeys, rows: [
                row(L10n.text("차단·해제 단축키"), control: shortcuts, height: 44),
                row(L10n.text("긴급 해제 단축키"), control: emergencyShortcut, height: 44),
                row(L10n.text("해제할 때 macOS 잠금"), subtitle: L10n.text("일반 해제·유지 시간 종료 시 인증합니다. 테스트·긴급 해제는 제외됩니다."), control: lockOnUnlock)
            ]),
            settingsSection(L10n.text("화면"), rows: [
                row(L10n.text("화면 어둡게"), subtitle: L10n.text("내장·지원 외장 화면에 적용하고, 해제하면 원래 밝기로 돌립니다."), control: dim),
                fades
            ]),
            settingsSection(L10n.text("앱"), rows: [
                row(L10n.text("언어 / Language"), subtitle: L10n.text("재시작 후 적용"), control: languageControls, height: 66),
                row(L10n.text("오류 알림 소리"), control: errorSound, height: 44)
            ])
        ])
    }

    /// Indents dependent controls without rebuilding them when their parent changes.
    private func dependent(_ content: NSView) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func workPage() -> NSView {
        let setup = button(L10n.text("보조 도구 설정"), action: #selector(showPermissionPane))
        setup.setAccessibilityIdentifier("work-helper-setup")
        return page(Pane.work.title, description: "", views: [
            settingsSection(L10n.text("잠자기·자동 잠금 방지"), rows: [
                row(L10n.text("잠자기·자동 잠금 방지"), subtitle: L10n.text("입력 차단 중 동작합니다. 끄면 덮개 유지도 함께 꺼집니다."), control: awake, height: 70)
            ]),
            settingsSection(L10n.text("덮개 유지"), accessory: setup, rows: [
                row(L10n.text("덮개를 닫아도 계속 실행"), subtitle: L10n.text("잠자기 방지를 함께 켭니다. 처음 사용할 때 보조 도구를 준비해주세요."), control: lid, height: 70),
                dependent(lidDurationContent()),
                dependent(row(L10n.text("배터리에서도 계속 실행"), subtitle: L10n.text("덮개 유지에만 적용됩니다. 전원을 분리해도 계속 실행합니다."), control: lidBattery, height: 70)),
                dependent(dependent(batteryReserve))
            ])
        ])
    }

    private func settingsSection(_ title: String, accessory: NSView? = nil, rows: [NSView]) -> NSView {
        let header = SettingsSectionHeader()
        let heading = stack([text(title, size: 13, weight: .semibold), spacer()] + (accessory.map { [$0] } ?? []), horizontal: true)
        heading.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(heading)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 36),
            heading.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            heading.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            heading.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        return group(rows, header: header)
    }

    private func contentDivider() -> NSView {
        let line = NSBox(); line.boxType = .separator
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func lidDurationContent() -> NSView {
        let hours = stack([text(L10n.text("직접 설정"), size: 12, secondary: true), spacer(), lidHours,
                           text(L10n.text("시간"), size: 12)], horizontal: true, spacing: 8)
        let inset = NSView()
        hours.translatesAutoresizingMaskIntoConstraints = false; inset.addSubview(hours)
        NSLayoutConstraint.activate([
            hours.leadingAnchor.constraint(equalTo: inset.leadingAnchor, constant: 16),
            hours.trailingAnchor.constraint(equalTo: inset.trailingAnchor, constant: -16),
            hours.topAnchor.constraint(equalTo: inset.topAnchor),
            hours.bottomAnchor.constraint(equalTo: inset.bottomAnchor, constant: -12)
        ])
        lidCustomRow = stack([inset], spacing: 0)
        inset.widthAnchor.constraint(equalTo: lidCustomRow.widthAnchor).isActive = true
        let result = stack([lidDurations, lidCustomRow], spacing: 0)
        for view in result.arrangedSubviews { view.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true }
        return result
    }

    private static func fadeLabel(_ duration: TimeInterval) -> String {
        duration == 0 ? L10n.text("즉시") : String(format: L10n.text("%g초"), duration)
    }

    private func statusValue(_ key: String) -> NSTextField {
        let field = text("", size: 12, secondary: true)
        field.alignment = .right
        if key == "physical" || key == "software" {
            field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            field.textColor = .labelColor
            field.alignment = .left
        }
        field.setAccessibilityIdentifier("status-\(key)")
        values[key] = field
        return field
    }

    private func testContent() -> NSStackView {
        lidLog = button(L10n.text("기록 보기"), action: #selector(lidLogPressed))
        lidLog.setAccessibilityIdentifier("lid-log")
        let trialControls = stack([trials, trial], horizontal: true, spacing: 8)
        let counters = stack([
            stack([text(L10n.text("차단한 직접 입력"), size: 11, secondary: true), statusValue("physical")], spacing: 4),
            stack([text(L10n.text("통과한 앱 입력"), size: 11, secondary: true), statusValue("software")], spacing: 4)
        ], horizontal: true, spacing: 36)
        testHint.font = .systemFont(ofSize: 11)
        testHint.textColor = .secondaryLabelColor
        let trialDetails = stack([
            row(L10n.text("테스트 자동 해제 시간"), subtitle: L10n.text("화면을 켜둔 채 시험하고, macOS 인증 없이 자동 해제합니다."), control: trialControls, height: 56, inset: 0),
            text(L10n.text("화면 밝기와 덮개 유지 동작은 이 테스트에 포함되지 않습니다."), size: 11, secondary: true),
            testHint
        ], spacing: 8)
        for view in trialDetails.arrangedSubviews { view.widthAnchor.constraint(equalTo: trialDetails.widthAnchor).isActive = true }
        statusTitle.font = .systemFont(ofSize: 13, weight: .medium)
        statusTitle.setAccessibilityIdentifier("diagnostic-session-state")
        statusImage.imageScaling = .scaleProportionallyUpOrDown
        statusImage.widthAnchor.constraint(equalToConstant: 12).isActive = true
        statusImage.heightAnchor.constraint(equalToConstant: 12).isActive = true
        let sessionSummary = stack([stack([statusImage, statusTitle], horizontal: true, spacing: 6), statusSubtitle], spacing: 8)
        statusSubtitle.font = .systemFont(ofSize: 12)
        statusSubtitle.textColor = .secondaryLabelColor
        let result = stack([
            settingsSection(L10n.text("입력 차단 테스트"), rows: [padded(trialDetails)]),
            settingsSection(L10n.text("현재 동작 상태"), rows: [
                padded(sessionSummary),
                row(L10n.text("잠자기 방지"), control: statusValue("power"), height: 44),
                row(L10n.text("자동 잠금 방지"), control: statusValue("idle"), height: 44),
                row(L10n.text("덮개 유지"), control: statusValue("lid"), height: 44)
            ]),
            settingsSection(L10n.text("최근 차단 집계"), rows: [
                padded(stack([counters, text(L10n.text("통과 횟수에는 DeskVeil의 자동 잠금 방지 신호도 포함됩니다. 일부 자동화 조작은 기록에 남지 않을 수 있습니다."), size: 11, secondary: true)], spacing: 10))
            ]),
            settingsSection(L10n.text("보조 도구 기록"), rows: [padded(stack([
                text(L10n.text("덮개 유지 보조 도구의 동작 기록을 엽니다."), size: 11, secondary: true), lidLog
            ], spacing: 10))])
        ], spacing: 16)
        for view in result.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true
        }
        return result
    }

    private func padded(_ content: NSView) -> NSView {
        let container = NSView()
        pin(content, to: container, inset: 16)
        return container
    }

    private func diagnosticsPage() -> NSView {
        page(Pane.diagnostics.title, description: "", views: [testContent()])
    }

    private func lidPermissionCard() -> NSView {
        lidSetup = button(L10n.text("보조 도구 설치…"), action: #selector(lidSetupPressed), prominent: true)
        lidSetup.setAccessibilityIdentifier("lid-service-setup")
        lidRemove = button(L10n.text("보조 도구 제거…"), action: #selector(lidRemovePressed))
        lidRemove.setAccessibilityIdentifier("lid-service-remove")
        lidRemove.toolTip = L10n.text("관리자 승인 후 덮개 유지 보조 도구와 동작 기록을 제거합니다. 입력 차단과 밝기 조절은 계속 사용할 수 있습니다.")
        lidPermissionValue.setAccessibilityIdentifier("lid-permission-state")
        lidActions = stack([lidSetup, lidRemove, spacer()], horizontal: true, spacing: 8)
        return permissionCard(L10n.text("덮개 유지 보조 도구"), value: lidPermissionValue, image: lidPermissionImage,
                              description: lidPermissionDescription, actions: lidActions)
    }

    private func permissionCard(_ title: String, value: NSTextField, image: NSImageView,
                                description: NSTextField, actions: NSStackView) -> NSView {
        value.font = .systemFont(ofSize: 12, weight: .medium)
        description.font = .systemFont(ofSize: 11)
        description.textColor = .secondaryLabelColor
        image.imageScaling = .scaleProportionallyUpOrDown
        image.widthAnchor.constraint(equalToConstant: 12).isActive = true
        image.heightAnchor.constraint(equalToConstant: 12).isActive = true
        let badge = NSView()
        for view in [image, value] {
            view.translatesAutoresizingMaskIntoConstraints = false
            badge.addSubview(view)
        }
        NSLayoutConstraint.activate([
            badge.heightAnchor.constraint(equalToConstant: 16),
            image.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
            image.centerYAnchor.constraint(equalTo: value.centerYAnchor),
            value.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            value.trailingAnchor.constraint(equalTo: badge.trailingAnchor),
            value.topAnchor.constraint(equalTo: badge.topAnchor),
            value.bottomAnchor.constraint(equalTo: badge.bottomAnchor)
        ])
        let content = stack([row(title, control: badge, height: 16, inset: 0), description, actions], spacing: 12)
        for view in content.arrangedSubviews { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        let body = NSView()
        pin(content, to: body, inset: 16)
        return group([body])
    }

    private func permissionPage() -> NSView {
        permissionValue.setAccessibilityIdentifier("permission-state")
        let open = button(L10n.text("시스템 설정 열기"), action: #selector(permissionsPressed), prominent: true)
        let retry = button(L10n.text("권한 다시 확인"), action: #selector(retryPressed))
        testLink.font = .systemFont(ofSize: 12)
        testLink.isBordered = false
        testLink.contentTintColor = .controlAccentColor
        testLink.alignment = .left
        permissionActions = stack([stack([open, retry, spacer()], horizontal: true), testLink], spacing: 8)
        testLink.target = self; testLink.action = #selector(showTestPane)
        testLink.bezelStyle = .inline
        testLink.setAccessibilityIdentifier("permission-test-link")
        let summary = permissionCard(L10n.text("손쉬운 사용"), value: permissionValue, image: permissionImage,
                                     description: permissionDescription, actions: permissionActions)
        repairOpen = button(L10n.text("시스템 설정 열기"), action: #selector(permissionsPressed))
        let reveal = button(L10n.text("Finder에서 앱 보기"), action: #selector(revealApp))
        let relaunch = button(L10n.text("앱 다시 시작"), action: #selector(relaunchPressed))
        let path = text(Bundle.main.bundleURL.path, size: 11, secondary: true)
        path.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        path.lineBreakMode = .byTruncatingMiddle
        path.maximumNumberOfLines = 1
        path.isSelectable = true
        let check = stack([
            text(L10n.text("먼저 권한을 다시 확인해주세요."), size: 12),
            stack([repairOpen, spacer()], horizontal: true, spacing: 8)
        ], spacing: 8)
        let repairDetails = stack([
            check,
            stack([
                text(L10n.text("계속 안 된다면 앱을 다시 등록해주세요."), size: 12),
                text(L10n.text("손쉬운 사용에서 기존 DeskVeil을 지운 뒤 아래 앱을 다시 추가해주세요. 재등록 후에도 안 되면 앱을 다시 시작해주세요."), size: 11, secondary: true),
                path, stack([reveal, relaunch, spacer()], horizontal: true, spacing: 8)
            ], spacing: 8)
        ], spacing: 18)
        for view in repairDetails.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: repairDetails.widthAnchor).isActive = true
        }
        repairSection = DisclosureSection(title: L10n.text("손쉬운 사용 문제 해결"), detail: L10n.text("허용했는데 입력 차단이 되지 않을 때"), id: "permission-repair", content: repairDetails)
        permissionButtons = [open, retry, repairOpen, reveal, relaunch, repairSection.header, testLink]
        return page(Pane.permissions.title, description: "", views: [
            summary, lidPermissionCard(), repairSection
        ])
    }

    func update(_ state: ControlWindowState) {
        languageChangeAllowed = state.languageChangeAllowed && !state.locked && !state.lidBusy && !state.updating && !state.privacyShielded
        language.isEnabled = !state.updating
        refreshLanguageAction()
        currentLocked = state.locked
        currentReady = state.ready && state.accessibility && !state.updating && !state.privacyShielded
        let editable = !state.locked && !state.lidBusy && !state.updating && !state.privacyShielded
        statusTitle.stringValue = state.locked ? state.title : (currentReady ? L10n.text("대기 중") : (state.accessibility ? L10n.text("입력 차단을 준비할 수 없습니다") : L10n.text("권한 설정이 필요합니다")))
        let shortcut = state.shortcut.label
        currentNormal = state.shortcut; currentEmergency = state.emergency
        emergencyHint.stringValue = state.emergency.label
        statusSubtitle.stringValue = state.locked ? L10n.text("%@로 해제 · %@로 긴급 해제", String(describing: shortcut), String(describing: state.emergency.label)) : (currentReady ? L10n.text("메뉴 막대 또는 %@로 자리 비움을 시작할 수 있습니다.", String(describing: shortcut)) : (state.accessibility ? L10n.text("접근 권한에서 연결 상태를 확인해주세요.") : L10n.text("접근 권한에서 손쉬운 사용을 허용해주세요.")))
        statusImage.image = NSImage(systemSymbolName: state.locked ? "lock.fill" : (currentReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill"), accessibilityDescription: nil)
        statusImage.contentTintColor = state.locked ? .controlAccentColor : (currentReady ? .systemGreen : .systemOrange)
        if !state.locked && state.issue != nil {
            if currentReady {
                statusTitle.stringValue = L10n.text("확인이 필요합니다")
                statusSubtitle.stringValue = L10n.text("아래 오류 내용을 확인해주세요.")
            }
            statusImage.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)
            statusImage.contentTintColor = .systemOrange
        }
        if state.updating {
            statusTitle.stringValue = L10n.text("업데이트 적용 중")
            statusSubtitle.stringValue = L10n.text("새 버전을 준비하고 있습니다. 잠시 기다려주세요.")
            statusImage.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            statusImage.contentTintColor = .controlAccentColor
        }
        if state.privacyShielded {
            statusTitle.stringValue = L10n.text("화면 가림 유지 중")
            statusSubtitle.stringValue = L10n.text("설정한 긴급 해제 단축키 또는 복구 명령으로 화면을 다시 볼 수 있습니다.")
        }
        dim.state = state.dim ? .on : .off; awake.state = state.awake ? .on : .off
        lockOnUnlock.state = state.lockOnUnlock ? .on : .off
        errorSound.state = state.errorSound ? .on : .off
        lid.state = state.lidEnabled ? .on : .off
        lid.isEnabled = editable
        lidBattery.state = state.lidOnBattery ? .on : .off
        lidBattery.isEnabled = lid.isEnabled && state.lidEnabled
        batteryReserve.isHidden = false
        batteryReserve.isEnabled = lidBattery.isEnabled && state.lidOnBattery
        batteryReserve.update(choices: BatteryReserve.choices.map { "\($0)%" },
            selectedIndex: BatteryReserve.choices.firstIndex(of: state.batteryReservePercent) ?? 0,
            detail: L10n.text("이 잔량 이하가 되면 작업 유지를 종료합니다. 다음 차단부터 적용됩니다."))
        if state.lidDurationSeconds == 0 { customDurationSelected = false }
        let preset = LidDuration.choices.firstIndex { $0.seconds == state.lidDurationSeconds }
        if preset == nil { customDurationSelected = true }
        if lidHours.currentEditor() == nil && state.lidDurationSeconds > 0 {
            lidHours.integerValue = state.lidDurationSeconds / 3600
        }
        lidCustomRow.isHidden = !customDurationSelected
        lidDurations.isEnabled = editable && state.lidEnabled
        lidHours.isEnabled = lidDurations.isEnabled
        let durationDetail = state.lidDurationSeconds == 0
            ? L10n.text("시간 제한 없이 유지합니다. 전원·배터리 조건과 응답 감시는 계속 적용됩니다.")
            : (state.lockOnUnlock ? L10n.text("시간이 끝나면 해제하고 macOS 인증으로 전환합니다. 새 차단부터 적용됩니다.") : L10n.text("시간이 끝나면 입력 차단을 해제합니다. 새 차단부터 적용됩니다."))
        lidDurations.update(choices: LidDuration.choices.map { $0.title } + [L10n.text("직접 설정")],
            selectedIndex: customDurationSelected ? LidDuration.choices.count : (preset ?? 0),
            value: customDurationSelected ? L10n.text("%@시간", String(describing: state.lidDurationSeconds / 3600)) : nil,
            detail: durationDetail)
        lidSetup.title = state.lidSetupTitle
        lidSetup.isHidden = !state.lidNeedsSetup
        lidSetup.isEnabled = editable
        lidRemove.isHidden = !state.lidHasService
        lidRemove.isEnabled = editable
        lidActions.isHidden = lidSetup.isHidden && lidRemove.isHidden
        let helperReady = state.lidInstalled && !state.lidNeedsSetup && !state.lidBusy
        lidPermissionValue.stringValue = state.lidBusy ? L10n.text("처리 중") : (helperReady ? L10n.text("준비됨") : (state.lidHasService ? L10n.text("연결 필요") : L10n.text("설치 필요")))
        lidPermissionValue.textColor = helperReady ? .systemGreen : .secondaryLabelColor
        lidPermissionImage.image = NSImage(systemSymbolName: helperReady ? "checkmark.circle.fill" : "exclamationmark.circle", accessibilityDescription: nil)
        lidPermissionImage.contentTintColor = helperReady ? .systemGreen : .secondaryLabelColor
        lidPermissionDescription.stringValue = L10n.text("선택 사항 · 덮개 유지에만 필요합니다. 처음 설치와 보조 도구 변경 시 관리자 승인이 필요합니다.")
        lidLog.isHidden = false
        lidLog.isEnabled = state.lidHasLog
        shortcuts.shortcut = state.shortcut; emergencyShortcut.shortcut = state.emergency
        if !fadeValues.contains(where: { abs($0 - state.fade) < 0.001 }) {
            fadeValues.append(state.fade); fadeValues.sort()
        }
        fades.update(choices: fadeValues.map(Self.fadeLabel),
            selectedIndex: fadeValues.firstIndex(where: { abs($0 - state.fade) < 0.001 }) ?? 2)
        for control in [dim, awake, shortcuts, emergencyShortcut, lockOnUnlock, errorSound, resetKeys!] { control.isEnabled = editable }
        trial.isEnabled = !state.locked && currentReady
        if state.lidBusy { trial.isEnabled = false }
        trials.isEnabled = !state.locked && currentReady
        testHint.stringValue = currentReady
            ? L10n.text("키보드·마우스는 막히고, 자동화의 클릭·입력은 동작하는지 확인해주세요.")
            : (state.accessibility ? L10n.text("접근 권한에서 입력 차단 연결을 복구해주세요.") : L10n.text("테스트를 실행하려면 접근 권한을 먼저 설정해주세요."))
        if state.updating { testHint.stringValue = L10n.text("업데이트가 끝나면 다시 사용할 수 있습니다.") }
        if state.privacyShielded { testHint.stringValue = L10n.text("화면 가림을 해제한 뒤 테스트할 수 있습니다.") }
        fades.isEnabled = editable && state.dim
        for button in permissionButtons { button.isEnabled = !state.locked && !state.updating && !state.privacyShielded }
        values["power"]?.stringValue = state.powerStatus
        values["idle"]?.stringValue = state.idleStatus
        values["lid"]?.stringValue = state.lidStatus
        values["physical"]?.stringValue = L10n.text("%@회", String(describing: state.physicalEvents.formatted()))
        values["software"]?.stringValue = L10n.text("%@회", String(describing: state.softwareEvents.formatted()))
        permissionValue.stringValue = state.accessibility ? L10n.text("허용됨") : L10n.text("허용 필요")
        permissionValue.textColor = state.accessibility ? .systemGreen : .secondaryLabelColor
        permissionDescription.stringValue = state.accessibility
            ? L10n.text("권한은 허용됐지만 입력 차단을 준비할 수 없습니다. ‘손쉬운 사용 문제 해결’에서 다시 확인해주세요.")
            : L10n.text("시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 DeskVeil을 켜주세요.")
        if currentReady { permissionDescription.stringValue = L10n.text("필수 권한이 준비됐습니다. 입력 차단 테스트로 동작을 확인할 수 있습니다.") }
        permissionDescription.isHidden = false
        permissionActions.isHidden = false
        testLink.isHidden = !currentReady
        repairOpen.isHidden = !state.accessibility
        permissionImage.image = NSImage(systemSymbolName: state.accessibility ? "checkmark.circle.fill" : "exclamationmark.circle", accessibilityDescription: nil)
        permissionImage.contentTintColor = state.accessibility ? .systemGreen : .secondaryLabelColor
        issueLabel.toolTip = state.issue
        issueLabel.stringValue = state.issue ?? ""
        issueLabel.isHidden = state.issue == nil
    }

    @objc private func selectPane(_ sender: NSButton) { selectPaneIndex(sender.tag) }
    private func selectPaneIndex(_ index: Int) {
        guard let pane = Pane(rawValue: index) else { return }
        showPane(pane)
    }
    func showPane(_ pane: Pane) {
        let index = pane.rawValue
        shortcuts.cancel(); emergencyShortcut.cancel()
        currentPane = pane
        for (position, page) in pages.enumerated() { page.isHidden = position != index }
        for (position, button) in navigation.enumerated() {
            button.state = position == index ? .on : .off
            button.needsDisplay = true
        }
    }
    @objc private func trialPressed() { if !currentLocked { if currentReady { onTrial(TimeInterval(trials.selectedTag())) } else { showPermissions() } } }
    @objc private func settingsChanged() {
        guard !currentLocked else { return }
        onSettings(dim.state == .on, awake.state == .on, fadeValues[fades.selectedIndex], lockOnUnlock.state == .on)
    }
    @objc private func resetShortcuts() {
        guard !currentLocked else { return }
        shortcuts.cancel(); emergencyShortcut.cancel()
        if let error = onShortcutChange(.normal, .emergency) {
            issueLabel.stringValue = error; issueLabel.isHidden = false
        }
    }
    func cancelShortcutRecording() { shortcuts.cancel(); emergencyShortcut.cancel() }
    var shortcutCaptureDiagnostics: [String: Any] {
        ["normal": shortcuts.lastEvent, "emergency": emergencyShortcut.lastEvent,
         "normalHadCandidate": shortcuts.lastHadCandidate, "emergencyHadCandidate": emergencyShortcut.lastHadCandidate,
         "appActive": NSApp.isActive, "windowKey": window?.isKeyWindow ?? false]
    }
    @objc private func errorSoundChanged() {
        guard !currentLocked else { return }
        onErrorSoundChange(errorSound.state == .on)
    }
    @objc private func lidChanged() { if !currentLocked { onLidChange(lid.state == .on) } }
    @objc private func lidBatteryChanged() { if !currentLocked { onLidBatteryChange(lidBattery.state == .on) } }
    private func batteryReserveChanged() {
        guard !currentLocked else { return }
        onBatteryReserveChange(BatteryReserve.choices[batteryReserve.selectedIndex])
    }
    private func lidDurationChanged() {
        guard !currentLocked else { return }
        customDurationSelected = lidDurations.selectedIndex == LidDuration.choices.count
        let seconds = customDurationSelected ? max(1, lidHours.integerValue) * 3600 : LidDuration.choices[lidDurations.selectedIndex].seconds
        onLidDurationChange(seconds)
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === lidHours, customDurationSelected, !currentLocked else { return }
        onLidDurationChange(min(LidDuration.maximumHours, max(1, lidHours.integerValue)) * 3600)
    }
    @objc private func lidSetupPressed() { if !currentLocked { onLidSetup() } }
    @objc private func lidRemovePressed() { if !currentLocked { onLidRemove() } }
    @objc private func lidLogPressed() { onLidLog() }
    @objc private func permissionsPressed() { onPermissions() }
    @objc private func retryPressed() { onRetry() }
    private func refreshLanguageAction() {
        let changed = language.indexOfSelectedItem >= 0 && (AppLanguage.allCases[language.indexOfSelectedItem] != initialLanguage || AppLanguage.allCases[language.indexOfSelectedItem] != AppLanguage.selection())
        applyLanguage.isEnabled = languageChangeAllowed && changed
    }
    @objc private func languageSelected() { refreshLanguageAction() }
    @objc private func applyLanguagePressed() {
        guard languageChangeAllowed, language.indexOfSelectedItem >= 0 else { return }
        let selected = AppLanguage.allCases[language.indexOfSelectedItem]
        guard selected != initialLanguage || selected != AppLanguage.selection() else { return }
        onLanguageChange(selected)
    }
    @objc private func relaunchPressed() { onRelaunch() }
    @objc private func revealApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    func showPermissions() { showPane(.permissions) }
    @objc private func showTestPane() { showPane(.diagnostics) }
    @objc private func showPermissionPane() { showPermissions() }
}
