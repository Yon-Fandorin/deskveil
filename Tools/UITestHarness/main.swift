import AppKit
import Darwin

final class TestDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var count = 0
    var status: NSTextField!
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = Bundle.main.bundleIdentifier == "dev.local.softlock.testpanel"
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = panel ? "SoftLock Test Panel — temporary test only" : "SoftLock Test Editor — temporary test only"
        window.center()
        let content = window.contentView!
        let title = NSTextField(labelWithString: "SoftLock UI automation test · temporary, no user documents")
        title.frame = NSRect(x: 20, y: 350, width: 580, height: 30)
        content.addSubview(title)
        status = NSTextField(labelWithString: "Checking SoftLock state…")
        status.frame = NSRect(x: 20, y: 310, width: 580, height: 30)
        content.addSubview(status)
        let text = NSTextField(string: "")
        text.placeholderString = "Enter a test message here"
        text.setAccessibilityIdentifier("test-input")
        text.frame = NSRect(x: 20, y: 240, width: 580, height: 40)
        content.addSubview(text)
        let button = NSButton(title: "Test click · count 0", target: self, action: #selector(clicked(_:)))
        button.setAccessibilityIdentifier("test-click")
        button.frame = NSRect(x: 20, y: 180, width: 260, height: 40)
        content.addSubview(button)
        let note = NSTextField(wrappingLabelWithString: "This window starts empty and never opens or saves user files. It only reads SoftLock's own status JSON. Close the app after the test.")
        note.frame = NSRect(x: 20, y: 55, width: 580, height: 90)
        content.addSubview(note)
        let mainMenu = NSMenu()
        let root = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Test App", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = appMenu
        mainMenu.addItem(root)
        NSApp.mainMenu = mainMenu
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.updateStatus() }
        updateStatus()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateStatus() {
        let root = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let candidates = ["dist/SoftLock-diagnostics.json", "dist-preview/SoftLock-diagnostics.json"]
            .compactMap { path -> (Date, [String: Any])? in
                let url = root.appendingPathComponent(path)
                guard let data = try? Data(contentsOf: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pid = json["pid"] as? Int32, pid > 0, kill(pid, 0) == 0,
                      let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      Date().timeIntervalSince(date) < 10 else { return nil }
                return (date, json)
            }.sorted { $0.0 > $1.0 }
        guard let json = candidates.first?.1 else { status.stringValue = "SoftLock: no live diagnostics"; return }
        status.stringValue = "SoftLock: \(json["locked"] as? Bool == true ? "LOCKED" : "UNLOCKED") · filter: \(json["tapEnabled"] as? Bool == true ? "ON" : "OFF") · test clicks: \(count)"
    }

    @objc func clicked(_ button: NSButton) {
        count += 1
        button.title = "Test click · count \(count)"
        updateStatus()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = TestDelegate()
app.delegate = delegate
app.run()
