import AppKit

// Compile with Localization.swift, Brand.swift and PrivacyShieldContent.swift only: no event tap, brightness,
// full-screen surface, shield lifecycle or power backend exists in this preview.
guard Bundle.main.bundleIdentifier == "dev.local.softlock.privacy-preview",
      CommandLine.arguments.count == 2 ||
        (CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--no-message") else { exit(2) }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let showsMessage = !CommandLine.arguments.contains("--no-message")
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let content = PrivacyShieldContent(showsMessage: showsMessage)
content.fitSurface(to: NSSize(width: 640, height: 440))
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 440),
    styleMask: [.titled], backing: .buffered, defer: false)
window.title = "DeskVeil · 화면 가림 미리보기"
window.isReleasedWhenClosed = false; window.contentView = content
window.orderFront(nil)
Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
    var results: [[String: Any]] = []
    for width: CGFloat in [640, 320] {
        content.fitSurface(to: NSSize(width: width, height: 440))
        window.setContentSize(NSSize(width: width, height: 440))
        window.layoutIfNeeded(); content.layoutSubtreeIfNeeded()
        let stack = content.subviews.first as? NSStackView
        let arranged = stack?.arrangedSubviews ?? []
        let frames = arranged.map { content.convert($0.bounds, from: $0) }
        let visible = frames.allSatisfy { content.bounds.insetBy(dx: -1, dy: -1).contains($0) }
        let actualSize = abs(content.bounds.width - width) < 1 && abs(content.bounds.height - 440) < 1
        let labels = arranged.compactMap { ($0 as? NSTextField)?.stringValue }
        let noRecoveryUI = !arranged.contains { $0 is NSButton }
        let expectedContent = showsMessage
            ? labels == [L10n.text("입력 차단이 중단되어 화면을 가렸습니다"), L10n.text("가림을 해제하기 전까지 이 화면을 유지합니다.")] &&
                arranged.count == 3 && arranged.filter { $0 is NSImageView }.count == 1
            : content.subviews.isEmpty
        guard visible, actualSize, noRecoveryUI, expectedContent,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            print("FAIL requested \(width)x440 actual \(content.bounds); content visible=\(visible); frames=\(frames)")
            fflush(stdout); exit(1)
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        try! data.write(to: output.appendingPathExtension("\(Int(width)).png"))
        results.append(["width": width, "actualContentWidth": content.bounds.width,
            "actualContentHeight": content.bounds.height, "allContentInBounds": visible, "noRecoveryUI": noRecoveryUI,
            "showsMessage": showsMessage, "visibleText": labels])
    }
    let report: [String: Any] = ["scenarios": results,
        "noInputOrPowerBackend": true, "noFullScreenSurface": true]
    try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathExtension("json"))
    print("PASS bounded native shield content:640/320px, showsMessage=\(showsMessage); no reveal button/shortcut/error details")
    window.close(); app.terminate(nil)
}
app.run()
