import AppKit

/// Captures only this window's gesture, consumes it through key-up, then commits.
final class ShortcutRecorder: NSButton {
    var shortcut = KeyboardShortcut.normal { didSet { if !recording { present(shortcut.label) } } }
    var onRecording: ((Bool) -> Void)?
    var onCommit: ((KeyboardShortcut) -> String?)?
    private(set) var recording = false
    private(set) var lastEvent = "idle"
    private(set) var lastHadCandidate = false
    private var candidate: KeyboardShortcut?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private let recorderName: String
    override var acceptsFirstResponder: Bool { true }

    init(label: String) {
        recorderName = label
        super.init(frame: .zero)
        title = shortcut.label; bezelStyle = .rounded; target = self; action = #selector(begin)
        present(shortcut.label)
        toolTip = L10n.text("클릭한 뒤 원하는 키 조합을 누르세요. Esc로 취소합니다.")
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.cancel(reason: "app-inactive") })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: nil, queue: .main) { [weak self] note in
                if (note.object as? NSWindow) === self?.window { self?.cancel(reason: "window-closed") }
            })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: nil, queue: .main) { [weak self] note in
                if (note.object as? NSWindow) === self?.window { self?.cancel(reason: "window-not-key") }
            })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
    @objc private func begin() {
        guard isEnabled else { return }
        if recording { cancel(); return }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        toolTip = L10n.text("클릭한 뒤 원하는 키 조합을 누르세요. Esc로 취소합니다.")
        setAccessibilityHelp(toolTip)
        recording = true; candidate = nil; lastEvent = "recording"; lastHadCandidate = false; onRecording?(true)
        present(L10n.text("키 조합을 누르세요…")); window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown,.keyUp,.leftMouseDown,.rightMouseDown]) { [weak self] event in
            guard let self, self.recording else { return event }
            guard event.window === self.window else {
                self.cancel(reason: event.window == nil ? "event-without-window" : "different-window"); return event
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if event.type == .rightMouseDown || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.cancel(reason: "outside-click")
                }
                return event
            }
            if event.type == .keyDown {
                if event.keyCode == 53 && event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty {
                    self.cancel(reason: "escape"); return nil
                }
                if !event.isARepeat && self.candidate == nil {
                    self.candidate = KeyboardShortcut(event: event)
                    self.lastEvent = "candidate-received"
                    self.lastHadCandidate = true
                    self.present(self.candidate!.label)
                }
                return nil
            }
            if let candidate = self.candidate, UInt32(event.keyCode) == candidate.keyCode {
                let error = self.onCommit?(candidate)
                self.finish(reason: error == nil ? "saved" : "rejected")
                if let error { self.toolTip = error; self.setAccessibilityHelp(error) }
            }
            return nil
        }
    }
    func cancel(reason: String = "cancelled") { if recording { finish(reason: reason) } }
    private func finish(reason: String) {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        recording = false; candidate = nil; present(shortcut.label); lastEvent = reason
        onRecording?(false)
    }
    private func present(_ value: String) {
        title = value; setAccessibilityLabel("\(recorderName), \(value)"); setAccessibilityValue(value)
    }
}
