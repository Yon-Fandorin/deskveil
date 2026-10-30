import AppKit

final class PreviewDelegate: NSObject, NSApplicationDelegate {
    var controls: ControlWindow!
    var statusItem: NSStatusItem!
    private let dashboard = MenuDashboard()
    private lazy var statusDashboard = StatusDashboard(dashboard: dashboard)
    private var menuRenderTimer: Timer?
    private var renderedWindow: NSWindow?
    private var renderedPanel: StatusDashboard?
    private var installationPreview: NSAlert?
    let transitionPanels = NativeTransitionPanels()
    private var failurePreviewGeneration: UInt64 = 0
    var dim = true
    var awake = true
    var shortcut = KeyboardShortcut.normal
    var emergency = KeyboardShortcut.emergency
    var fade = 0.3
    var lockOnUnlock = true
    var errorSound = false
    var lidMode = true
    var lidOnBattery = false
    var batteryReservePercent = BatteryReserve.defaultPercent
    var lidDurationSeconds = 0
    private var previewOffDisplays: Set<String> = []
    var previewLocked = false
    var previewRemaining: Int?
    var scenario = "ready"
    var ready: Bool { scenario != "permission-needed" && scenario != "tap-failed" }
    var permissionGranted: Bool { scenario != "permission-needed" }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let popoverAuditPath = Bundle.main.object(forInfoDictionaryKey: "SoftLockPopoverAuditPath") as? String
        let renderIndex = CommandLine.arguments.firstIndex(of: "--render-dashboard")
        let dashboardRenderPath = renderIndex.flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
            ?? Bundle.main.object(forInfoDictionaryKey: "SoftLockDashboardRenderPath") as? String
            ?? popoverAuditPath.map { $0 + ".content.png" }
        let rendering = CommandLine.arguments.contains("--render") || dashboardRenderPath != nil
        NSApp.setActivationPolicy(rendering ? .prohibited : .regular)
        scenario = Bundle.main.object(forInfoDictionaryKey: "SoftLockPreviewScenario") as? String ?? "ready"
        if CommandLine.arguments.contains("--permission-needed") || Bundle.main.object(forInfoDictionaryKey: "SoftLockPreviewNeedsPermission") as? Bool == true { scenario = "permission-needed" }
        if let dashboardRenderPath {
            NSApp.appearance = NSAppearance(named: (CommandLine.arguments.contains("--dark") || Bundle.main.object(forInfoDictionaryKey: "SoftLockDesignAppearance") as? String == "dark") ? .darkAqua : .aqua)
            let dashboard = MenuDashboard()
            let live = CommandLine.arguments.contains("--live-displays")
            var samples = [
                DisplayStatus(id: 1, name: "내장 Retina 디스플레이", builtIn: true, asleep: false, active: true, brightness: 0.64, blackOutput: false),
                DisplayStatus(id: 2, name: "Studio Display", builtIn: false, asleep: false, active: true, brightness: 0, blackOutput: true),
                DisplayStatus(id: 3, name: "외장 디스플레이", builtIn: false, asleep: true, active: false, brightness: nil, blackOutput: nil)
            ]
            if Bundle.main.object(forInfoDictionaryKey: "SoftLockDashboardManyDisplays") as? Bool == true {
                samples += (4...8).map { DisplayStatus(id: UInt32($0), name: "가상 디스플레이 \($0)", builtIn: false,
                    asleep: false, active: true, brightness: nil, blackOutput: false) }
            }
            samples = samples.map { display in
                var sample = display; sample.identity = "preview-\(sample.id)"; return sample
            }
            var renderedState = MenuDashboardState(displays: live ? DisplayStatusReader().read() : samples,
                locked: false, awake: false, dimming: false, issue: nil, displayControlsEnabled: !live,
                offDisplays: ["preview-2"])
            dashboard.update(renderedState)
            let panel = StatusDashboard(dashboard: dashboard, behavior: popoverAuditPath == nil ? .transient : .applicationDefined)
            func previewMenu(remaining: Int? = nil) -> NSMenu {
                let menu = QuickMenu.make(target: self, locked: false, ready: true, shortcut: shortcut,
                    remaining: remaining, toggle: #selector(togglePreview), settings: #selector(showSettings),
                    permissions: #selector(showPermissions), about: #selector(showAbout), quit: #selector(quitPreview))
                // This render-only branch does not construct the settings controller.
                // Do not expose enabled actions that silently do nothing.
                for item in menu.items where ["quick-toggle", "quick-settings"].contains(item.identifier?.rawValue) {
                    item.isEnabled = false
                    item.toolTip = "렌더링 미리보기에서는 사용할 수 없습니다."
                }
                return menu
            }
            panel.updateMenu(previewMenu())
            renderedPanel = panel
            let originals = samples
            var auditPowerEvents: [[String: Any]] = []
            dashboard.onDisplayPower = { [weak dashboard, weak panel] display, off in
                // Exercise the real AppKit target/action path without touching
                // hardware or rewriting the synthetic topology under audit.
                if popoverAuditPath != nil {
                    auditPowerEvents.append(["id": Int(display.id), "identity": display.identity ?? "",
                                             "name": display.name, "off": off])
                    return
                }
                guard let key = display.identity else { return }
                if off { renderedState.offDisplays.insert(key) } else { renderedState.offDisplays.remove(key) }
                renderedState.displays = originals.map { original in
                    let dark = original.identity.map { renderedState.offDisplays.contains($0) } ?? false
                    return DisplayStatus(id: original.id, name: original.name, builtIn: original.builtIn,
                        asleep: original.asleep, active: original.active,
                        brightness: original.brightness.map { dark ? 0 : max($0, 0.64) },
                        blackOutput: dark, identity: original.identity)
                }
                dashboard?.update(renderedState); panel?.resize()
            }
            let backing = panel.view
            backing.appearance = NSApp.appearance
            backing.layoutSubtreeIfNeeded()
            var layout: [[String: Any]] = []
            func inspect(_ view: NSView) {
                let rect = view.convert(view.bounds, to: backing)
                layout.append(["type": String(describing: type(of: view)), "text": (view as? NSTextField)?.stringValue ?? "",
                    "x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height, "hidden": view.isHidden])
                view.subviews.forEach(inspect)
            }
            inspect(backing)
            if let data = try? JSONSerialization.data(withJSONObject: layout, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: dashboardRenderPath + ".json"))
            }
            guard let bitmap = backing.bitmapImageRepForCachingDisplay(in: backing.bounds) else { exit(1) }
            backing.cacheDisplay(in: backing.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            do { try data.write(to: URL(fileURLWithPath: dashboardRenderPath)) }
            catch { fputs(error.localizedDescription, stderr); exit(1) }
            if let popoverAuditPath {
                let statusAnchor = Bundle.main.object(forInfoDictionaryKey: "SoftLockPopoverAuditStatusItem") as? Bool == true
                NSApp.setActivationPolicy(statusAnchor ? .accessory : .regular)
                let anchor: NSView
                if statusAnchor {
                    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                    statusItem.button?.image = DeskVeilBrand.mark(size: 20)
                    anchor = statusItem.button!
                } else {
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 120),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    window.title = "실제 팝오버 갱신 검증 · 테스트 데이터"
                    let button = NSButton(title: "팝오버 검증", target: nil, action: nil)
                    button.frame = NSRect(x: 160, y: 65, width: 140, height: 30)
                    window.contentView?.addSubview(button)
                    window.center(); renderedWindow = window
                    window.makeKeyAndOrderFront(nil)
                    anchor = button
                }
                NSApp.activate(ignoringOtherApps: true)
                var samples: [[String: Any]] = []
                let identifier = DisplayIdentifier()
                var identifyEvents: [UInt32] = []
                dashboard.onDisplayIdentify = { selected in
                    identifyEvents.append(selected.id)
                    // Component audit: mock display topology, real AppKit overlay.
                    // Only this callback may show it, so action wiring is exercised.
                    if let target = DisplayIdentification.resolve(selected, current: renderedState.displays ?? []),
                       let screen = anchor.window?.screen ?? NSScreen.main {
                        identifier.show(target, in: screen.frame)
                    }
                }
                var step = 0
                var animationMidpoint: [String: Any] = [:]
                var savedDisplays: [DisplayStatus]?
                let started = ProcessInfo.processInfo.systemUptime
                func powerButton(_ id: UInt32) -> NSButton? {
                    func find(_ view: NSView) -> NSButton? {
                        if let button = view as? NSButton,
                           button.accessibilityIdentifier() == "display-power-\(id)" { return button }
                        for child in view.subviews { if let button = find(child) { return button } }
                        return nil
                    }
                    return find(dashboard)
                }
                func snapshot() -> [String: Any] {
                    var result = panel.layoutSnapshot
                    result["identification"] = identifier.snapshot
                    result["keyWindow"] = NSApp.keyWindow?.windowNumber ?? 0
                    var rows: [[String: Any]] = []
                    func inspect(_ view: NSView) {
                        if let button = view as? NSButton, button.accessibilityIdentifier().hasPrefix("display-power-"),
                           let row = button.superview?.superview, let wrapper = row.superview {
                            var texts: [String] = []
                            var levels: [[String: Any]] = []
                            func inspectRow(_ child: NSView) {
                                if let label = child as? NSTextField { texts.append(label.stringValue) }
                                if child.accessibilityRole() == .progressIndicator {
                                    levels.append(["value": child.accessibilityValue() as? String ?? "",
                                                   "frame": NSStringFromRect(child.convert(child.bounds, to: wrapper))])
                                }
                                child.subviews.forEach(inspectRow)
                            }
                            inspectRow(row)
                            rows.append(["id": button.tag, "control": String(describing: ObjectIdentifier(button)),
                                         "identifier": button.accessibilityIdentifier(), "enabled": button.isEnabled,
                                         "label": button.accessibilityLabel() ?? "", "texts": texts, "levels": levels,
                                         "bounds": NSStringFromRect(wrapper.bounds),
                                         "powerFrame": NSStringFromRect(button.convert(button.bounds, to: wrapper))])
                        }
                        view.subviews.forEach(inspect)
                    }
                    inspect(dashboard)
                    result["auditRows"] = rows
                    result["auditModel"] = (renderedState.displays ?? []).map {
                        ["id": Int($0.id), "identity": $0.identity ?? "", "name": $0.name,
                         "percent": $0.brightnessPercent.map { $0 as Any } ?? NSNull(),
                         "enabled": renderedState.displayControlsEnabled && $0.identity != nil
                            && !renderedState.pendingDisplays.contains($0.identity ?? "")
                            && (renderedState.offDisplays.contains($0.identity ?? "") || ($0.active && !$0.asleep))] as [String: Any]
                    }
                    result["focusedObject"] = (panel.view.window?.firstResponder as? NSView)
                        .map { String(describing: ObjectIdentifier($0)) } ?? ""
                    return result
                }
                func sendPowerAction(_ button: NSButton?, expected: DisplayStatus?) -> [String: Any] {
                    let start = auditPowerEvents.count
                    let sent = button.flatMap { control in
                        control.action.map { NSApp.sendAction($0, to: control.target, from: control) }
                    } ?? false
                    let expectedEvents: [[String: Any]] = expected.map {
                        [["id": Int($0.id), "identity": $0.identity ?? "", "name": $0.name,
                          "off": !renderedState.offDisplays.contains($0.identity ?? "")]]
                    } ?? []
                    return ["sent": sent, "expected": expectedEvents, "observed": Array(auditPowerEvents.dropFirst(start))]
                }
                func replaceDisplay(_ id: UInt32, with display: DisplayStatus) {
                    renderedState.displays = renderedState.displays?.map { $0.id == id ? display : $0 }
                }
                // A status item's window may not be attached/visible until AppKit
                // processes menu-bar registration after applicationDidFinishLaunching.
                func showIfReady() {
                    guard !panel.isShown, anchor.window?.isVisible == true,
                          !anchor.bounds.isEmpty, !anchor.visibleRect.isEmpty else { return }
                    panel.toggle(relativeTo: anchor)
                }
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self, weak panel] timer in
                    guard let self, let panel else { timer.invalidate(); return }
                    let elapsed = ProcessInfo.processInfo.systemUptime - started
                    if !panel.isShown && step == 0 && elapsed < 10 { showIfReady() }
                    let failure: String?
                    if elapsed >= 45 { failure = "Native popover audit exceeded its 45-second deadline" }
                    else if !panel.isShown && (step > 0 || elapsed >= 10) {
                        failure = step == 0 ? "Popover never became visible within 10 seconds" : "Popover closed before audit completed"
                    } else { failure = nil }
                    if let failure {
                        timer.invalidate(); self.menuRenderTimer = nil
                        let report: [String: Any] = ["error": failure, "elapsed": elapsed, "completedSteps": step,
                            "anchor": statusAnchor ? "status-item" : "window",
                            "anchorHasWindow": anchor.window != nil,
                            "anchorWindowVisible": anchor.window?.isVisible ?? false,
                            "anchorBounds": NSStringFromRect(anchor.bounds),
                            "anchorVisibleRect": NSStringFromRect(anchor.visibleRect),
                            "anchorWindowFrame": NSStringFromRect(anchor.window?.frame ?? .zero),
                            "samples": samples]
                        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                            try? data.write(to: URL(fileURLWithPath: popoverAuditPath + ".error.json"), options: .atomic)
                        }
                        return
                    }
                    guard panel.isShown else { return }
                    var focusEstablished = false
                    if step == 2 { focusEstablished = panel.focusForAudit("quick-about") }
                    if step == 7 { focusEstablished = panel.focusForAudit("display-power-5"); dashboard.scrollForAudit() }
                    if (8...10).contains(step) { focusEstablished = panel.focusForAudit("display-power-5") }
                    if [11, 12, 14, 15, 16].contains(step) { focusEstablished = panel.focusForAudit("quick-about") }
                    if step == 13 { focusEstablished = panel.focusForAudit("display-power-9") }
                    let before = snapshot()
                    var actionChecks: [[String: Any]] = []
                    var identifyCheck: [String: Any] = [:]
                    var visualCheck: [String: Any] = [:]
                    let phase: String
                    switch step {
                    case 0: phase = "refresh"
                    case 1: phase = "countdown-start"; panel.updateMenu(previewMenu(remaining: 15))
                    case 2: phase = "countdown-tick"; panel.updateMenu(previewMenu(remaining: 14))
                    case 3:
                        phase = "height-grow"
                        renderedState.dimming = true
                        renderedState.issue = "미리보기: 상태 메시지를 추가하여 실제 패널 높이 변경을 검사합니다."
                        dashboard.update(renderedState)
                    case 4:
                        phase = "height-shrink"
                        renderedState.dimming = false; renderedState.issue = nil
                        dashboard.update(renderedState)
                    case 5:
                        phase = "many-displays"
                        var displays = originals
                        if displays.count < 8 {
                            displays += ((displays.count + 1)...8).map {
                                DisplayStatus(id: UInt32($0), name: "가상 디스플레이 \($0)", builtIn: false,
                                    asleep: false, active: true, brightness: nil, blackOutput: false,
                                    identity: "preview-\($0)")
                            }
                        }
                        renderedState.displays = displays
                        dashboard.update(renderedState)
                    case 6: phase = "scroll-seed"; dashboard.scrollForAudit()
                    case 7:
                        phase = "value-refresh"
                        renderedState.displays = renderedState.displays?.map { display in
                            DisplayStatus(id: display.id, name: display.name, builtIn: display.builtIn,
                                asleep: display.asleep, active: display.active,
                                brightness: display.brightness.map { $0 == 0.64 ? 0.52 : $0 },
                                blackOutput: display.blackOutput, identity: display.identity)
                        }
                        dashboard.update(renderedState)
                    case 8:
                        phase = "brightness-known"
                        replaceDisplay(5, with: DisplayStatus(id: 5, name: "외장 밝기 갱신", builtIn: false,
                            asleep: false, active: true, brightness: 0.37, blackOutput: false, identity: "preview-5"))
                        dashboard.update(renderedState)
                    case 9:
                        phase = "brightness-unknown"
                        replaceDisplay(5, with: DisplayStatus(id: 5, name: "외장 밝기 갱신", builtIn: false,
                            asleep: false, active: true, brightness: nil, blackOutput: false, identity: "preview-5"))
                        dashboard.update(renderedState)
                    case 10:
                        phase = "brightness-invalid"
                        // Rejected observations must behave like an unavailable
                        // reading: keep the empty brightness track, never fake a value.
                        replaceDisplay(5, with: DisplayStatus(id: 5, name: "외장 잘못된 밝기", builtIn: false,
                            asleep: false, active: true, brightness: .infinity, blackOutput: false, identity: "preview-5"))
                        dashboard.update(renderedState)
                    case 11:
                        phase = "hotplug-reorder"
                        let removed = powerButton(4)
                        renderedState.displays = [DisplayStatus(id: 9, name: "연결된 새 디스플레이", builtIn: false,
                            asleep: false, active: true, brightness: 0.42, blackOutput: false, identity: "preview-9")]
                            + Array((renderedState.displays ?? []).filter { $0.id != 4 }.reversed())
                        dashboard.update(renderedState)
                        actionChecks.append(sendPowerAction(removed, expected: nil))
                    case 12:
                        phase = "display-id-reuse"
                        let stale = powerButton(5)
                        let replacement = DisplayStatus(id: 5, name: "ID 재사용 디스플레이", builtIn: false,
                            asleep: false, active: true, brightness: 0.61, blackOutput: false, identity: "preview-replacement-5")
                        replaceDisplay(5, with: replacement)
                        dashboard.update(renderedState)
                        actionChecks.append(sendPowerAction(stale, expected: nil))
                        actionChecks.append(sendPowerAction(powerButton(5), expected: replacement))
                    case 13:
                        phase = "same-identity-new-id"
                        let retained = powerButton(9)
                        let replacement = DisplayStatus(id: 19, name: "ID가 변경된 디스플레이", builtIn: false,
                            asleep: false, active: true, brightness: 0.48, blackOutput: false, identity: "preview-9")
                        replaceDisplay(9, with: replacement)
                        dashboard.update(renderedState)
                        actionChecks.append(sendPowerAction(retained, expected: replacement))
                    case 14:
                        phase = "duplicate-identities"
                        // DisplayStatusReader clears identities when UUIDs collide.
                        // Preserve its boundary invariant while rendering both rows.
                        for id in [UInt32(5), 19] {
                            replaceDisplay(id, with: DisplayStatus(id: id, name: "중복 UUID 디스플레이 \(id)", builtIn: false,
                                asleep: false, active: true, brightness: id == 5 ? 0.22 : nil,
                                blackOutput: false, identity: nil))
                        }
                        dashboard.update(renderedState)
                        for id in [UInt32(5), 19] { actionChecks.append(sendPowerAction(powerButton(id), expected: nil)) }
                    case 15:
                        phase = "duplicate-refresh"
                        for id in [UInt32(5), 19] {
                            replaceDisplay(id, with: DisplayStatus(id: id, name: "중복 UUID 갱신 \(id)", builtIn: false,
                                asleep: false, active: true, brightness: id == 5 ? nil : 0.73,
                                blackOutput: false, identity: nil))
                        }
                        dashboard.update(renderedState)
                        for id in [UInt32(5), 19] { actionChecks.append(sendPowerAction(powerButton(id), expected: nil)) }
                    case 16:
                        phase = "identity-recovered"
                        for id in [UInt32(5), 19] {
                            replaceDisplay(id, with: DisplayStatus(id: id, name: "식별된 디스플레이 \(id)", builtIn: false,
                                asleep: false, active: true, brightness: 0.55, blackOutput: false, identity: "recovered-\(id)"))
                        }
                        dashboard.update(renderedState)
                        for id in [UInt32(5), 19] {
                            actionChecks.append(sendPowerAction(powerButton(id), expected: renderedState.displays?.first { $0.id == id }))
                        }
                    case 17:
                        phase = "reopen"
                        panel.close(); panel.toggle(relativeTo: anchor)
                    case 18: phase = "countdown-end"; panel.updateMenu(previewMenu())
                    case 20:
                        phase = "identify-display"
                        func identifyButton(_ view: NSView, id: UInt32) -> NSButton? {
                            if let button = view as? NSButton,
                               button.accessibilityIdentifier() == "display-identify-\(id)" { return button }
                            for child in view.subviews { if let found = identifyButton(child, id: id) { return found } }
                            return nil
                        }
                        if let selected = renderedState.displays?.first,
                           let button = identifyButton(dashboard, id: selected.id),
                           let replacementIndex = renderedState.displays?.firstIndex(where: { $0.id == selected.id }) {
                            let stale = button
                            let replacement = DisplayStatus(id: selected.id, name: "식별할 디스플레이", builtIn: false,
                                asleep: false, active: true, brightness: 0.55, blackOutput: false, identity: "identify-replacement")
                            renderedState.displays?[replacementIndex] = replacement
                            dashboard.update(renderedState)
                            let initialPowerCount = auditPowerEvents.count
                            let initialIdentifyCount = identifyEvents.count
                            let keyWindow = NSApp.keyWindow
                            if let action = stale.action { NSApp.sendAction(action, to: stale.target, from: stale) }
                            let staleIgnored = identifyEvents.count == initialIdentifyCount
                            let current = identifyButton(dashboard, id: replacement.id)
                            current?.performClick(nil)
                            let rowActionOnly = auditPowerEvents.count == initialPowerCount
                                && Array(identifyEvents.dropFirst(initialIdentifyCount)) == [replacement.id]
                            var powerExcludedFromGesture = false
                            var labelExcludedFromGesture = false
                            var brightnessGestureDelivered = false
                            if let power = powerButton(replacement.id), let row = power.superview?.superview,
                               let gesture = row.gestureRecognizers.first {
                                func allowsGesture(at view: NSView) -> Bool {
                                    guard let event = NSEvent.mouseEvent(with: .leftMouseDown,
                                        location: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil),
                                        modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { return false }
                                    return dashboard.gestureRecognizer(gesture, shouldAttemptToRecognizeWith: event)
                                }
                                powerExcludedFromGesture = !allowsGesture(at: power)
                                labelExcludedFromGesture = current.map { !allowsGesture(at: $0) } ?? false
                                if let brightness = row.subviews.last, brightness !== power.superview,
                                   allowsGesture(at: brightness), let action = gesture.action {
                                    NSApp.sendAction(action, to: gesture.target, from: gesture)
                                    brightnessGestureDelivered = auditPowerEvents.count == initialPowerCount
                                        && Array(identifyEvents.dropFirst(initialIdentifyCount)) == [replacement.id, replacement.id]
                                }
                            }
                            if let screen = anchor.window?.screen ?? NSScreen.main {
                                let shown = identifier.isVisible
                                    && identifier.snapshot["frame"] as? String == NSStringFromRect(screen.frame)
                                identifyCheck = ["staleIgnored": staleIgnored, "rowActionOnly": rowActionOnly,
                                    "powerExcluded": powerExcludedFromGesture, "shown": shown,
                                    "labelExcluded": labelExcludedFromGesture, "brightnessGestureDelivered": brightnessGestureDelivered,
                                    "focusPreserved": NSApp.keyWindow === keyWindow]
                                if let badge = identifier.markerView?.subviews.first,
                                   let bitmap = badge.bitmapImageRepForCachingDisplay(in: badge.bounds) {
                                    badge.cacheDisplay(in: badge.bounds, to: bitmap)
                                    if let data = bitmap.representation(using: .png, properties: [:]) {
                                        try? data.write(to: URL(fileURLWithPath: popoverAuditPath + ".identify.png"))
                                    }
                                }
                            }
                        }
                    case 21, 22: phase = "identify-wait"
                    case 23: phase = "identify-expired"
                    case 24:
                        phase = "brightness-animation-start"
                        if let selected = renderedState.displays?.first {
                            replaceDisplay(selected.id, with: DisplayStatus(id: selected.id, name: selected.name,
                                builtIn: selected.builtIn, asleep: false, active: true, brightness: 0.9,
                                blackOutput: false, identity: selected.identity))
                            dashboard.update(renderedState)
                            visualCheck["reduceMotion"] = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                                animationMidpoint = dashboard.interactionSnapshot["brightness"] as? [String: Any] ?? [:]
                            }
                        }
                    case 25:
                        phase = "brightness-animation-end"
                        visualCheck["midpoint"] = animationMidpoint
                        visualCheck["reduceMotion"] = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    case 26:
                        phase = "brightness-all-unavailable"
                        savedDisplays = renderedState.displays
                        renderedState.displays = renderedState.displays?.map {
                            DisplayStatus(id: $0.id, name: $0.name, builtIn: $0.builtIn, asleep: $0.asleep,
                                active: $0.active, brightness: nil, blackOutput: $0.blackOutput, identity: $0.identity)
                        }
                        dashboard.update(renderedState)
                    case 27:
                        phase = "brightness-all-recovered"
                        renderedState.displays = savedDisplays
                        dashboard.update(renderedState)
                    case 28:
                        phase = "single-display-pending"
                        if let selected = renderedState.displays?.first, let identity = selected.identity {
                            renderedState.pendingDisplays.insert(identity)
                            replaceDisplay(selected.id, with: DisplayStatus(id: selected.id, name: selected.name,
                                builtIn: selected.builtIn, asleep: false, active: true, brightness: nil,
                                blackOutput: false, identity: identity))
                            dashboard.update(renderedState)
                        }
                    case 29:
                        phase = "single-display-off"
                        visualCheck["reduceMotion"] = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                        if let selected = renderedState.displays?.first, let identity = selected.identity {
                            renderedState.pendingDisplays.remove(identity)
                            renderedState.offDisplays.insert(identity)
                            replaceDisplay(selected.id, with: DisplayStatus(id: selected.id, name: selected.name,
                                builtIn: selected.builtIn, asleep: false, active: true, brightness: 0,
                                blackOutput: true, identity: identity))
                            dashboard.update(renderedState)
                        }
                    case 30: phase = "single-display-off-end"
                    case 31:
                        phase = "outside-click"
                        func clickEvent(in view: NSView, point: NSPoint, type: NSEvent.EventType = .leftMouseDown) -> NSEvent? {
                            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
                        }
                        if let inside = clickEvent(in: panel.view, point: NSPoint(x: panel.view.bounds.midX, y: panel.view.bounds.midY)),
                           let anchorClick = clickEvent(in: anchor, point: NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)),
                           let outside = clickEvent(in: anchor, point: NSPoint(x: anchor.bounds.maxX + 100, y: anchor.bounds.midY), type: .rightMouseDown) {
                            panel.handleMouseDown(inside)
                            visualCheck["insidePreserved"] = panel.isShown
                            panel.handleMouseDown(anchorClick)
                            visualCheck["anchorPreserved"] = panel.isShown
                            panel.close()
                            let isolatedDashboard = MenuDashboard()
                            isolatedDashboard.update(renderedState)
                            let transient = StatusDashboard(dashboard: isolatedDashboard)
                            transient.toggle(relativeTo: anchor)
                            visualCheck["monitorsInstalled"] = transient.layoutSnapshot["dismissalMonitoring"]
                            // Dispatch within this isolated app, never post an OS mouse event.
                            NSApp.sendEvent(outside)
                            visualCheck["outsideClosed"] = !transient.isShown
                            visualCheck["monitorsRemoved"] = transient.layoutSnapshot["dismissalMonitoring"] as? Bool == false
                            transient.close()
                            panel.toggle(relativeTo: anchor)
                            visualCheck["reopened"] = panel.isShown
                        }
                    case 32:
                        phase = "update-waiting"
                        renderedState.updateStatus = "v0.7.99 업데이트 대기 · 입력 차단 해제 후 적용"
                        dashboard.update(renderedState)
                    case 33:
                        phase = "update-cancelled"
                        renderedState.updateStatus = nil
                        dashboard.update(renderedState)
                    default: phase = "refresh"
                    }
                    panel.resize()
                    let after = snapshot()
                    samples.append(["phase": phase, "anchor": statusAnchor ? "status-item" : "window", "before": before, "after": after,
                                    "focusEstablished": focusEstablished, "actionChecks": actionChecks,
                                    "identifyCheck": identifyCheck, "visualCheck": visualCheck])
                    step += 1
                    guard step >= 34 else { return }
                    timer.invalidate(); self.menuRenderTimer = nil
                    if let data = try? JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: URL(fileURLWithPath: popoverAuditPath + ".json"))
                    }
                    if let nativeContent = panel.view.window?.contentView,
                       let bitmap = nativeContent.bitmapImageRepForCachingDisplay(in: nativeContent.bounds) {
                        nativeContent.cacheDisplay(in: nativeContent.bounds, to: bitmap)
                        if let image = bitmap.representation(using: .png, properties: [:]) {
                            try? image.write(to: URL(fileURLWithPath: popoverAuditPath + ".png"))
                        }
                    }
                }
                menuRenderTimer = timer
                RunLoop.main.add(timer, forMode: .common)
                DispatchQueue.main.async { showIfReady() }
                return
            }
            if Bundle.main.object(forInfoDictionaryKey: "SoftLockDashboardRenderPath") != nil {
                NSApp.setActivationPolicy(.regular)
                let window = NSWindow(contentRect: backing.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "대시보드 배치 확인 · 테스트 데이터"
                window.contentView = backing
                window.center()
                renderedWindow = window
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            exit(0)
        }
        dashboard.onDisplayPower = { [weak self] display, off in
            guard let self, let key = display.identity else { return }
            if off { self.previewOffDisplays.insert(key) } else { self.previewOffDisplays.remove(key) }
            self.refresh()
        }
        applyScenario()
        if CommandLine.arguments.contains("--battery") { lidOnBattery = true }
        if CommandLine.arguments.contains("--dark") || Bundle.main.object(forInfoDictionaryKey: "SoftLockDesignAppearance") as? String == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        controls = ControlWindow(onTrial: { [weak self] seconds in
            self?.scenario = "trial"; self?.previewLocked = true; self?.previewRemaining = Int(seconds); self?.refresh()
        },
            onSettings: { [weak self] dim, awake, fade, lockOnUnlock in
                guard let self else { return }
                self.dim = dim; self.awake = awake; self.fade = fade
                self.lockOnUnlock = lockOnUnlock
                self.refresh()
            }, onPermissions: {}, onRetry: {}, onRelaunch: {},
            onShortcutChange: { [weak self] normal, emergency in
                guard let self else { return "창을 다시 열어주세요." }
                if let error = normal.validationError(other: emergency) ?? emergency.validationError(other: normal) { return error }
                self.shortcut = normal; self.emergency = emergency; self.refresh(); return nil
            },
            onErrorSoundChange: { [weak self] enabled in self?.errorSound = enabled; self?.refresh() },
            onLidChange: { [weak self] enabled in self?.lidMode = enabled; self?.refresh() },
            onLidBatteryChange: { [weak self] enabled in self?.lidOnBattery = enabled; self?.refresh() },
            onBatteryReserveChange: { [weak self] percent in self?.batteryReservePercent = percent; self?.refresh() },
            onLidDurationChange: { [weak self] seconds in self?.lidDurationSeconds = seconds; self?.refresh() })
        controls.window?.titleVisibility = .visible
        controls.window?.title = "디자인 미리보기 · 실제 입력 차단 없음"
        refresh()
        if rendering {
            if CommandLine.arguments.contains("--custom-duration") { lidDurationSeconds = 36 * 3600; refresh() }
            if CommandLine.arguments.contains("--lid-update") { scenario = "lid-update"; refresh() }
            if let index = CommandLine.arguments.firstIndex(of: "--settings-pane"), index + 1 < CommandLine.arguments.count {
                let panes: [String: ControlWindow.Pane] = ["general": .general, "work": .work, "permissions": .permissions, "diagnostics": .diagnostics]
                guard let pane = panes[CommandLine.arguments[index + 1]] else { exit(2) }
                controls.showPane(pane)
            }
            if CommandLine.arguments.contains("--small") { controls.window?.setContentSize(NSSize(width: 760, height: 420)) }
            let content = controls.window!.contentView!
            if CommandLine.arguments.contains("--expanded") {
                func expand(_ view: NSView) {
                    if let section = view as? DisclosureSection { section.setExpanded(true, scroll: false) }
                    view.subviews.forEach(expand)
                }
                expand(content)
                controls.window?.setContentSize(NSSize(width: 760, height: 1050))
            }
            content.layoutSubtreeIfNeeded()
            if let index = CommandLine.arguments.firstIndex(of: "--settings-audit"), index + 1 < CommandLine.arguments.count {
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                let views = descendants(content)
                func find(_ identifier: String) -> NSView? {
                    views.first { $0.identifier?.rawValue == identifier || $0.accessibilityIdentifier() == identifier }
                }
                func selected(_ index: Int) -> Bool {
                    let pages = views.filter { $0.identifier?.rawValue.hasPrefix("settings-page-") == true && !$0.isHidden }
                    return pages.count == 1 && pages.first?.identifier?.rawValue == "settings-page-\(index)" && (find("settings-pane-\(index)") as? NSButton)?.state == .on
                }
                func check(_ condition: Bool, _ label: String) {
                    if !condition { fputs("Settings audit failed: \(label)\n", stderr); exit(1) }
                }
                for index in 0..<4 {
                    (find("settings-pane-\(index)") as? NSButton)?.performClick(nil)
                    check(selected(index), "sidebar route \(index)")
                }
                controls.showPermissions(); check(selected(2), "permission entry point")
                (find("permission-test-link") as? NSButton)?.performClick(nil)
                check(selected(3), "permission to test route")
                check(find("setup-notice") == nil, "sidebar has no session-status row")
                controls.showPane(.diagnostics)
                check(find("diagnostic-session-state")?.isHiddenOrHasHiddenAncestor == false, "session state belongs to diagnostics")
                scenario = "ready"; controls.showPane(.work)
                lidMode = false; lidOnBattery = true; refresh()
                guard let battery = find("battery-reserve") as? NSSlider else { exit(1) }
                check(!battery.isEnabled && !battery.isHiddenOrHasHiddenAncestor, "dependent value remains visible when off")
                let saved = battery.integerValue
                lidMode = true; refresh()
                check(battery.isEnabled && battery.integerValue == saved, "dependent value preserved on re-enable")
                previewLocked = true; refresh()
                check(!battery.isEnabled && !(find("keep-awake-with-lid-closed") as! NSSwitch).isEnabled, "blocking disables power settings")
                let result: [String: Any] = ["passed": true, "sidebarPages": 4, "routes": 6, "dependencies": 3]
                try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                print("Settings navigation and dependency audit passed"); exit(0)
            }
            guard let index = CommandLine.arguments.firstIndex(of: "--render"), index + 1 < CommandLine.arguments.count,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { exit(1) }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            do { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])); print("Rendered preview"); exit(0) }
            catch { fputs(error.localizedDescription, stderr); exit(1) }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = DeskVeilBrand.mark(size: 20)
        statusItem.menu = QuickMenu.make(target: self, locked: false, ready: ready, shortcut: shortcut,
            remaining: nil, toggle: #selector(togglePreview), settings: #selector(showSettings),
            permissions: #selector(showPermissions), about: #selector(showAbout), quit: #selector(quitPreview))
        let main = NSMenu()
        let appItem = NSMenuItem(title: "DeskVeil", action: nil, keyEquivalent: "")
        appItem.submenu = statusItem.menu
        main.addItem(appItem)
        let modes = NSMenu()
        modes.autoenablesItems = false
        for (value, title) in [("ready", "정상"), ("permission-needed", "권한 없음"), ("tap-failed", "권한 허용·필터 실패"), ("locked", "일반 차단"), ("trial", "15초 테스트"), ("issue", "밝기 복원 오류"), ("dim-off", "화면 옵션 끄기"), ("installation-start", "설치 안내"), ("installation-existing", "설치된 앱 열기"), ("installation", "설치 완료")] {
            let item = NSMenuItem(title: title, action: #selector(chooseScenario(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = value
            item.identifier = NSUserInterfaceItemIdentifier("preview-" + value)
            modes.addItem(item)
        }
        modes.addItem(.separator())
        let failure = NSMenuItem(title: "전환 오류 화면 · 4초 미리보기", action: #selector(showFailurePreview), keyEquivalent: "")
        failure.target = self; modes.addItem(failure)
        let appearance = NSMenuItem(title: "다크 모드", action: #selector(toggleAppearance), keyEquivalent: "")
        appearance.target = self; modes.addItem(appearance)
        let modeItem = NSMenuItem(title: "미리보기", action: nil, keyEquivalent: "")
        modeItem.submenu = modes; main.addItem(modeItem)
        NSApp.mainMenu = main
        refresh()
        controls.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        showInstallationPreview()
        if let path = Bundle.main.object(forInfoDictionaryKey: "SoftLockMenuRenderPath") as? String {
            var attempts = 0
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
                attempts += 1
                guard let self else { timer.invalidate(); return }
                if self.statusDashboard.isShown, case let content = self.statusDashboard.view,
                   let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    // Offscreen views include transparent native materials. Initialize the
            // backing pixels so untouched areas never contain allocator contents.
            if let pixels = bitmap.bitmapData { pixels.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh) }
            content.cacheDisplay(in: content.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: path))
                        timer.invalidate()
                        self.statusDashboard.close()
                        return
                    }
                }
                if attempts >= 20 {
                    timer.invalidate()
                    try? Data("Menu capture timed out".utf8).write(to: URL(fileURLWithPath: path + ".error"))
                    self.statusDashboard.close()
                }
            }
            menuRenderTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            DispatchQueue.main.async { [weak self] in
                guard let self, let button = self.statusItem.button else { return }
                self.statusDashboard.toggle(relativeTo: button)
            }
        }
    }
    private func showInstallationPreview() {
        if (CommandLine.arguments.contains("--installation") || scenario.hasPrefix("installation")), let window = controls.window {
            guard window.attachedSheet == nil else { return }
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "preview"
            let alert = scenario == "installation-start" || scenario == "installation-existing" ?
                InstallationFlow.installAlert(installed: scenario == "installation-existing") :
                InstallationFlow.cleanupAlert(download: URL(fileURLWithPath: "/Downloads/DeskVeil-\(version)-macOS-arm64.dmg")).alert
            installationPreview = alert
            alert.beginSheetModal(for: window) { [weak self] _ in self?.installationPreview = nil }
        }
    }
    func refresh() {
        let title = previewRemaining.map { "테스트 중 · \($0)초 후 해제" } ?? "입력 차단 중"
        let issue = scenario == "issue" ? "화면 복원에 실패했습니다. DeskVeil을 다시 실행해주세요." : (scenario == "tap-failed" ? "입력 차단 연결을 준비하지 못했습니다. 권한을 다시 확인해주세요." : nil)
        controls.update(ControlWindowState(locked: previewLocked, ready: ready, title: title,
            dim: dim, awake: awake, shortcut: shortcut, emergency: emergency, fade: fade, lockOnUnlock: lockOnUnlock,
            errorSound: errorSound,
            powerStatus: previewLocked ? "동작 중 · 전원 연결됨" : "차단 시작 시 동작", idleStatus: previewLocked ? "동작 확인됨" : "꺼짐", physicalEvents: 507,
            softwareEvents: 10, accessibility: permissionGranted, issue: issue,
            lidEnabled: lidMode, lidOnBattery: lidOnBattery, batteryReservePercent: batteryReservePercent, lidStatus: scenario == "lid-update" ? "보조 도구 업데이트 필요" : "준비됨",
            lidDurationSeconds: lidDurationSeconds,
            lidInstalled: scenario != "lid-update", lidNeedsSetup: scenario == "lid-update", lidSetupTitle: "보조 도구 업데이트…",
            lidHasLog: true, lidHasService: true))
        dashboard.update(MenuDashboardState(displays: [
            DisplayStatus(id: 1, name: "내장 Retina 디스플레이", builtIn: true,
                          asleep: false, active: true, brightness: (previewLocked && dim) || previewOffDisplays.contains("preview-1") ? 0 : 0.64,
                          blackOutput: false, identity: "preview-1"),
            DisplayStatus(id: 2, name: "외장 디스플레이", builtIn: false,
                          asleep: false, active: true, brightness: nil, blackOutput: (previewLocked && dim) || previewOffDisplays.contains("preview-2"), identity: "preview-2")
        ], locked: previewLocked, awake: previewLocked && awake, dimming: previewLocked && dim, issue: issue,
            displayControlsEnabled: !previewLocked, offDisplays: previewOffDisplays))
        if let statusItem {
            statusItem.menu = QuickMenu.make(target: self, locked: previewLocked, ready: ready,
                shortcut: shortcut, remaining: previewRemaining,
                locksOnUnlock: previewLocked && previewRemaining == nil && lockOnUnlock, toggle: #selector(togglePreview),
                settings: #selector(showSettings), permissions: #selector(showPermissions),
                about: #selector(showAbout), quit: #selector(quitPreview))
            let menu = statusItem.menu!
            NSApp.mainMenu?.items.first?.submenu = menu
            statusDashboard.updateMenu(menu)
            statusItem.menu = nil
            statusItem.button?.target = self
            statusItem.button?.action = #selector(showStatusDashboard)
        }
    }
    func applyScenario() {
        previewLocked = scenario == "locked" || scenario == "trial"
        previewRemaining = scenario == "trial" ? 15 : nil
        dim = scenario != "dim-off"
    }
    @objc func chooseScenario(_ sender: NSMenuItem) {
        scenario = sender.representedObject as? String ?? "ready"
        applyScenario(); refresh(); showInstallationPreview()
    }
    @objc func toggleAppearance() {
        NSApp.appearance = NSAppearance(named: NSApp.appearance?.name == .darkAqua ? .aqua : .darkAqua)
    }
    @objc func showFailurePreview() {
        failurePreviewGeneration += 1
        let generation = failurePreviewGeneration
        _ = transitionPanels.showFailure(CoverCommand(action: "failure", id: generation,
            reason: "macOS 잠금 화면으로 전환하지 못했습니다.", retry: shortcut.label, emergency: emergency.label))
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.failurePreviewGeneration == generation else { return }
            self.transitionPanels.hide(duration: 0)
        }
    }
    @objc func showStatusDashboard() {
        statusDashboard.toggle(relativeTo: statusItem.button!)
    }
    @objc func togglePreview() {
        guard controls != nil else { return }
        scenario = previewLocked ? "ready" : "locked"
        applyScenario(); refresh()
    }
    @objc func showSettings() { controls?.showWindow(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func showPermissions() { showSettings(); controls.showPermissions() }
    @objc func showAbout() { QuickMenu.showAbout() }
    @objc func quitPreview() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { failurePreviewGeneration += 1; transitionPanels.hide(duration: 0) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // A menu-bar audit has no ordinary window, and its reopen scenario
        // temporarily closes the popover. Keep the audit alive until it records.
        Bundle.main.object(forInfoDictionaryKey: "SoftLockPopoverAuditPath") == nil
    }
}
let app = NSApplication.shared
let delegate = PreviewDelegate()
app.delegate = delegate
app.run()
