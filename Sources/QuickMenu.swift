import AppKit

/// The menu handles everyday actions; the settings window owns configuration and tests.
enum QuickMenu {
    static func make(target: AnyObject, locked: Bool, ready: Bool, shortcut: KeyboardShortcut,
                     remaining: Int?, locksOnUnlock: Bool = false, handoffPending: Bool = false,
                     toggle: Selector, settings: Selector,
                     permissions: Selector, about: Selector, quit: Selector) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        @discardableResult func add(_ title: String, _ action: Selector, id: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.identifier = NSUserInterfaceItemIdentifier(id)
            menu.addItem(item)
            return item
        }
        if let remaining {
            let countdown = NSMenuItem(title: L10n.text("%@초 후 자동 해제", String(describing: remaining)), action: nil, keyEquivalent: "")
            countdown.identifier = NSUserInterfaceItemIdentifier("quick-countdown")
            countdown.isEnabled = false
            menu.addItem(countdown)
        }
        let unlockTitle = handoffPending ? L10n.text("Mac 잠금 전환 중…") : (locksOnUnlock ? L10n.text("Mac 잠금으로 전환") : L10n.text("자리 비움 해제"))
        let primary = add(locked ? unlockTitle : (ready ? L10n.text("자리 비움 시작") : L10n.text("접근 권한 설정…")),
                          locked || ready ? toggle : permissions, id: "quick-toggle")
        primary.isEnabled = !handoffPending
        if locked || ready {
            // The physical event tap owns activation. A menu equivalent would
            // execute it again when AppKit receives the same capture gesture.
            primary.toolTip = shortcut.label
        }
        add(L10n.text("설정…"), settings, id: "quick-settings")
        menu.addItem(.separator())
        add(L10n.text("DeskVeil 정보"), about, id: "quick-about")
        add(L10n.text("DeskVeil 종료"), quit, id: "quick-quit")
        return menu
    }

    static func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 3
        let credits = NSAttributedString(string: L10n.text("화면을 가리고 키보드·마우스 입력을 차단합니다.\n\nmacOS 암호 잠금은 별도로 동작합니다."), attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ])
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "DeskVeil", .credits: credits
        ]
        options[.applicationIcon] = NSApp.applicationIconImage
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
