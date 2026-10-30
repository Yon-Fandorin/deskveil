import AppKit

private final class DisclosureCell: NSButtonCell {
    var detail = ""

    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        if state == .on {
            let dark = controlView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            NSColor.labelColor.withAlphaComponent(dark ? 0.055 : 0.025).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10).fill()
        }
        if isHighlighted {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: frame.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
        let foreground: NSColor = isEnabled ? .labelColor : .disabledControlTextColor
        let secondary: NSColor = isEnabled ? .secondaryLabelColor : .disabledControlTextColor
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: foreground
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: secondary
        ]
        let copyWidth = max(0, frame.width - 132)
        (title as NSString).draw(in: NSRect(x: frame.minX + 16, y: frame.midY - 18,
                                           width: copyWidth, height: 18), withAttributes: titleAttributes)
        (detail as NSString).draw(in: NSRect(x: frame.minX + 16, y: frame.midY + 3,
                                            width: copyWidth, height: 16), withAttributes: detailAttributes)
        let hint = state == .on ? L10n.text("접기") : L10n.text("펼치기")
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .right
        var hintAttributes = detailAttributes
        hintAttributes[.paragraphStyle] = paragraph
        (hint as NSString).draw(in: NSRect(x: frame.maxX - 80, y: frame.midY - 8,
                                          width: 44, height: 16), withAttributes: hintAttributes)
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [secondary]))
        let symbol = state == .on ? "chevron.up" : "chevron.down"
        if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
            let scale = min(12 / icon.size.width, 12 / icon.size.height)
            let size = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
            icon.draw(in: NSRect(x: frame.maxX - 22 - size.width / 2, y: frame.midY - size.height / 2,
                                 width: size.width, height: size.height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

private final class DisclosureButton: NSButton {
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}

/// A native button with a stable header and inline content. No action leaves this section.
final class DisclosureSection: NSBox {
    let header: NSButton = DisclosureButton()
    private let details: NSView
    private let divider = NSBox()
    private let body = NSView()
    private(set) var isExpanded = false

    init(title: String, detail: String, id: String, content: NSView) {
        details = content
        super.init(frame: .zero)
        boxType = .custom; titlePosition = .noTitle
        borderWidth = 1; cornerRadius = 10
        borderColor = .separatorColor; fillColor = .controlBackgroundColor
        contentViewMargins = .zero
        let cell = DisclosureCell(textCell: title)
        cell.detail = detail
        header.cell = cell; header.title = title
        header.setButtonType(.momentaryChange)
        header.isBordered = false
        header.target = self; header.action = #selector(toggle)
        header.focusRingType = .exterior
        header.setAccessibilityIdentifier(id)
        header.setAccessibilityLabel(title)
        header.setAccessibilityHelp(detail)
        header.setAccessibilityExpanded(false)
        header.heightAnchor.constraint(equalToConstant: 56).isActive = true
        divider.boxType = .separator
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        details.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(details)
        NSLayoutConstraint.activate([
            details.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            details.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),
            details.topAnchor.constraint(equalTo: body.topAnchor, constant: 12),
            details.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -16)
        ])
        let layout = NSStackView(views: [header, divider, body])
        layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 0
        layout.translatesAutoresizingMaskIntoConstraints = false
        contentView!.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            layout.topAnchor.constraint(equalTo: contentView!.topAnchor),
            layout.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor)
        ])
        for view in layout.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        }
        divider.isHidden = true; body.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggle() {
        setExpanded(!isExpanded)
    }

    func setExpanded(_ expanded: Bool, scroll: Bool = true) {
        isExpanded = expanded
        divider.isHidden = !isExpanded; body.isHidden = !isExpanded
        header.state = isExpanded ? .on : .off
        header.setAccessibilityExpanded(isExpanded)
        header.needsDisplay = true
        window?.contentView?.layoutSubtreeIfNeeded()
        if isExpanded && scroll { scrollToVisible(bounds) }
    }
}
