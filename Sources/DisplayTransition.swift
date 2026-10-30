import AppKit

struct CoverCommand: Codable {
    var action: String
    var id: UInt64
    var duration: Double = 0
    var reason: String = ""
    var retry: String = ""
    var emergency: String = ""
}
struct CoverReply: Codable { let id: UInt64; let state: String }

/// The helper owns the visible state. Old commands/completions cannot remove a new cover.
struct CoverSession {
    private(set) var id: UInt64 = 0
    private(set) var state = "idle"
    mutating func apply(_ command: CoverCommand) -> Bool {
        if command.action == "ping" { return true }
        guard ["show", "failure", "hide"].contains(command.action), command.id >= id else { return false }
        id = command.id
        switch command.action {
        case "show": state = "covered"
        case "failure": state = "failure"
        case "hide": state = "revealing"
        default: return false
        }
        return true
    }
    mutating func didHide(id: UInt64) -> Bool {
        guard id == self.id, state == "revealing" else { return false }
        state = "idle"; return true
    }
}

final class NativeTransitionPanels {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private var panels: [NSPanel] = []
    private var fading: [NSPanel] = []
    private var failure: CoverCommand?
    private var announced = ""

    var presented: Bool {
        let expected = Set(NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        })
        let covered = Set(panels.compactMap {
            ($0.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        })
        return !expected.isEmpty && covered == expected && panels.allSatisfy { panel in
            guard let screen = panel.screen,
                  let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(panel.windowNumber)) as? [[String: Any]],
                  let window = windows.first,
                  window[kCGWindowIsOnscreen as String] as? Bool == true,
                  let alpha = window[kCGWindowAlpha as String] as? Double, alpha >= 0.999,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.contains(CGDisplayBounds(display.uint32Value))
        }
    }

    func show(rebuild: Bool = false, resetAnnouncement: Bool = true) -> Bool {
        failure = nil
        if resetAnnouncement { announced = "" }
        if !rebuild && !panels.isEmpty {
            for panel in panels { panel.contentView?.subviews.forEach { $0.removeFromSuperview() }; panel.setAccessibilityElement(false) }
            return true
        }
        let previous = panels + fading
        let next = NSScreen.screens.map { screen -> NSPanel in
            // Login's zoom can shrink ordinary app windows. Keep black margins
            // outside the display until loginwindow's own opaque surface is ready.
            let frame = screen.frame.insetBy(dx: -screen.frame.width / 8, dy: -screen.frame.height / 8)
            let panel = Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.backgroundColor = .black; panel.isOpaque = true
            panel.hasShadow = false; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true; panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.animationBehavior = .none; panel.setAccessibilityElement(false)
            panel.orderFrontRegardless(); panel.displayIfNeeded()
            return panel
        }
        guard !next.isEmpty, next.allSatisfy(\.isVisible) else {
            for panel in next { panel.close() }; return false
        }
        panels = next; fading = []
        // Replacement is already opaque before any old window is removed.
        for panel in previous { panel.orderOut(nil); panel.close() }
        return true
    }

    func showFailure(_ command: CoverCommand, rebuild: Bool = false) -> Bool {
        guard show(rebuild: rebuild, resetAnnouncement: false) else { return false }
        failure = command
        let reason = command.reason
        for panel in panels {
            guard let content = panel.contentView else { continue }
            func label(_ value: String, size: CGFloat, weight: NSFont.Weight, opacity: CGFloat) -> NSTextField {
                let field = NSTextField(wrappingLabelWithString: value)
                field.font = .systemFont(ofSize: size, weight: weight)
                field.textColor = .white.withAlphaComponent(opacity); field.alignment = .center
                field.setAccessibilityElement(true); return field
            }
            let heading = label(L10n.text("잠금 화면으로 전환하지 못했습니다"), size: 20, weight: .semibold, opacity: 1)
            let detail = label(reason, size: 14, weight: .regular, opacity: 0.75)
            let keys = label(L10n.text("%@  다시 시도\n%@  긴급 해제", String(describing: command.retry), String(describing: command.emergency)), size: 14, weight: .medium, opacity: 1)
            let stack = NSStackView(views: [heading, detail, keys])
            stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 20
            stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                stack.widthAnchor.constraint(equalToConstant: min(440, panel.frame.width - 48))
            ])
            panel.setAccessibilityElement(true); panel.setAccessibilityLabel(L10n.text("DeskVeil 잠금 전환 오류"))
        }
        let announcement = L10n.text("%@ %@로 다시 시도하거나 %@로 긴급 해제할 수 있습니다.", String(describing: reason), String(describing: command.retry), String(describing: command.emergency))
        if announcement != announced, let panel = panels.first {
            announced = announcement
            NSAccessibility.post(element: panel, notification: .announcementRequested,
                userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        return true
    }

    func rebuild() {
        if let failure { _ = showFailure(failure, rebuild: true) }
        else if !panels.isEmpty { _ = show(rebuild: true) }
    }
    func hide(duration: TimeInterval, completion: @escaping () -> Void = {}) {
        let hiding = panels; panels = []; failure = nil; announced = ""
        if duration <= 0 {
            for panel in hiding + fading { panel.orderOut(nil); panel.close() }
            fading = []; completion(); return
        }
        fading.append(contentsOf: hiding)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            for panel in hiding { panel.animator().alphaValue = 0 }
        } completionHandler: { [weak self] in
            for panel in hiding { panel.orderOut(nil); panel.close() }
            self?.fading.removeAll { panel in hiding.contains { $0 === panel } }
            completion()
        }
    }
}

/// Parent-side IPC only. All AppKit cover windows belong to the watchdog helper.
final class DisplayTransitionCover {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var messages = GuardianMessages()
    private var currentID: UInt64 = 0
    private var releaseTimeout: Timer?
    private(set) var active = false
    private(set) var preparing = false
    var onReply: ((CoverReply) -> Void)?
    var onExit: (() -> Void)?
    var running: Bool { process?.isRunning == true }

    private func start() throws {
        if let process, process.isRunning { return }
        output?.readabilityHandler = nil; try? output?.close(); try? input?.close()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--transition-cover-guardian"]
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        child.standardInput = stdinPipe; child.standardOutput = stdoutPipe; child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                guard let self, self.process === child else { return }
                self.output?.readabilityHandler = nil; try? self.input?.close(); try? self.output?.close()
                self.process = nil; self.input = nil; self.output = nil
                self.releaseTimeout?.invalidate(); self.releaseTimeout = nil
                let needsRecovery = self.active || self.preparing
                self.active = false; self.preparing = false
                if needsRecovery { self.onExit?() }
            }
        }
        try child.run()
        process = child; input = stdinPipe.fileHandleForWriting; output = stdoutPipe.fileHandleForReading
        messages = GuardianMessages()
        // A failed launch must not leave a child-capturing handler retaining its pipes.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                guard let self, self.process === child else { return }
                for line in self.messages.append(data) {
                    guard let reply = try? JSONDecoder().decode(CoverReply.self, from: Data(line.utf8)),
                          reply.id == self.currentID else { continue }
                    self.preparing = false
                    if reply.state == "covered" || reply.state == "failure" { self.active = true }
                    if reply.state == "released" {
                        self.active = false; self.releaseTimeout?.invalidate(); self.releaseTimeout = nil
                    }
                    self.onReply?(reply)
                }
            }
        }
    }
    @discardableResult func prepare(id: UInt64) -> Bool {
        releaseTimeout?.invalidate(); releaseTimeout = nil
        do { try start() } catch { return false }
        currentID = id; preparing = true
        return send(CoverCommand(action: "show", id: id))
    }
    @discardableResult func showFailure(id: UInt64, reason: String, retry: String, emergency: String) -> Bool {
        releaseTimeout?.invalidate(); releaseTimeout = nil
        do { try start() } catch { return false }
        currentID = id; preparing = true
        return send(CoverCommand(action: "failure", id: id, reason: reason, retry: retry, emergency: emergency))
    }
    func reveal(id: UInt64, duration: TimeInterval = 0) {
        releaseTimeout?.invalidate(); releaseTimeout = nil
        currentID = id; preparing = false
        if process == nil { active = false; return }
        // The helper may already have painted before its prepare ACK arrives.
        // Treat it as covered until the matching release ACK, including early emergency exit.
        active = true
        _ = send(CoverCommand(action: "hide", id: id, duration: duration))
        let timer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
            guard let self, self.currentID == id, self.active else { return }
            // This child owns no saved brightness. Killing a stuck release removes
            // its windows without disturbing the independent brightness guardian.
            self.process?.terminate()
        }
        releaseTimeout = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func heartbeat() { _ = send(CoverCommand(action: "ping", id: currentID)) }
    private func send(_ command: CoverCommand) -> Bool {
        guard let input, var data = try? JSONEncoder().encode(command) else { return false }
        data.append(10)
        do { try input.write(contentsOf: data); return true }
        catch { try? input.close(); self.input = nil; return false }
    }
    func close() {
        releaseTimeout?.invalidate(); releaseTimeout = nil
        _ = send(CoverCommand(action: "quit", id: currentID))
        try? input?.close(); input = nil
    }
}

private final class CoverGuardianRuntime: NSObject, NSApplicationDelegate {
    private let headless: Bool
    private let panels: NativeTransitionPanels?
    private var session = CoverSession()
    private var messages = GuardianMessages()
    private var lastHeartbeat = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    private var presentationTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    init(headless: Bool) {
        self.headless = headless
        panels = headless ? nil : NativeTransitionPanels()
    }
    func applicationDidFinishLaunching(_ notification: Notification) { start() }
    func start() {
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard let self else { return }
                if data.isEmpty { self.shutdown(); return }
                for line in self.messages.append(data) {
                    guard let command = try? JSONDecoder().decode(CoverCommand.self, from: Data(line.utf8)) else { continue }
                    self.lastHeartbeat = ProcessInfo.processInfo.systemUptime
                    self.handle(command)
                }
            }
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            if ProcessInfo.processInfo.systemUptime - self.lastHeartbeat > 4 { self.shutdown() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.panels?.rebuild() }
    }
    private func emit(id: UInt64, state: String) {
        if var data = try? JSONEncoder().encode(CoverReply(id: id, state: state)) {
            data.append(10); try? FileHandle.standardOutput.write(contentsOf: data)
        }
    }
    private func acknowledgePresentation(id: UInt64, state: String) {
        guard panels != nil else { emit(id: id, state: state); return }
        let earliest = ProcessInfo.processInfo.systemUptime + 0.05
        let deadline = earliest + 1
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, self.session.id == id, self.session.state == state else { timer.invalidate(); return }
            let now = ProcessInfo.processInfo.systemUptime
            if now >= earliest && self.panels?.presented == true {
                timer.invalidate(); self.presentationTimer = nil
                self.emit(id: id, state: state)
            } else if now >= deadline {
                timer.invalidate(); self.presentationTimer = nil
                self.emit(id: id, state: "failed")
            }
        }
        presentationTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func handle(_ command: CoverCommand) {
        if command.action == "quit" { shutdown(); return }
        guard session.apply(command) else { return }
        if command.action != "ping" { presentationTimer?.invalidate(); presentationTimer = nil }
        switch command.action {
        case "show":
            if panels?.show() ?? true { acknowledgePresentation(id: command.id, state: "covered") }
            else { emit(id: command.id, state: "failed") }
        case "failure":
            if panels?.showFailure(command) ?? true { acknowledgePresentation(id: command.id, state: "failure") }
            else { emit(id: command.id, state: "failed") }
        case "hide":
            let id = command.id
            let completed = { [weak self] in
                guard let self, self.session.didHide(id: id) else { return }
                self.emit(id: id, state: "released")
            }
            if let panels { panels.hide(duration: min(0.15, max(0, command.duration)), completion: completed) }
            else { completed() }
        default: break
        }
    }
    private func shutdown() {
        presentationTimer?.invalidate(); presentationTimer = nil
        timer?.invalidate(); FileHandle.standardInput.readabilityHandler = nil
        panels?.hide(duration: 0)
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        exit(0)
    }
}

func runTransitionCoverGuardian() -> Never {
    signal(SIGPIPE, SIG_IGN)
    let headless = CommandLine.arguments.contains("--headless")
    let delegate = CoverGuardianRuntime(headless: headless)
    if headless {
        delegate.start(); RunLoop.main.run()
    } else {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory); application.delegate = delegate
        application.run()
    }
    exit(0)
}
