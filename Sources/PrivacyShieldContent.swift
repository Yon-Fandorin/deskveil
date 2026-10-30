import AppKit

/// Shared by the real shield and a bounded preview with no input/power backend.
final class PrivacyShieldContent: NSView {
    private var surfaceWidth: NSLayoutConstraint?
    private var surfaceHeight: NSLayoutConstraint?
    private var messageWidth: NSLayoutConstraint?
    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        func label(_ text: String, size: CGFloat, weight: NSFont.Weight, opacity: CGFloat) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = .white.withAlphaComponent(opacity); field.alignment = .center
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return field
        }
        let icon = NSImageView()
        icon.image = DeskVeilBrand.mark(size: 36)
        icon.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        icon.contentTintColor = .white.withAlphaComponent(0.8)
        let stack = NSStackView(views: [icon,
            label(L10n.text("입력 차단이 중단되어 화면을 가렸습니다"), size: 20, weight: .semibold, opacity: 1),
            label(L10n.text("가림을 해제하기 전까지 이 화면을 유지합니다."), size: 13, weight: .regular, opacity: 0.7)
        ])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        let preferredWidth = stack.widthAnchor.constraint(equalTo: widthAnchor, constant: -48)
        preferredWidth.priority = .defaultHigh
        let maximumWidth = stack.widthAnchor.constraint(lessThanOrEqualToConstant: 440)
        messageWidth = maximumWidth
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor), preferredWidth,
            maximumWidth,
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48)])
        for view in stack.arrangedSubviews {
            if view is NSTextField { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            else { view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true }
        }
        setAccessibilityLabel(L10n.text("DeskVeil 화면 가림"))
    }
    /// The window owns its geometry. Intrinsic label sizes must never resize a
    /// privacy panel away from the display it is meant to cover.
    func fitSurface(to size: NSSize, visibleSize: NSSize? = nil) {
        guard size.width > 0, size.height > 0 else { return }
        if surfaceWidth == nil {
            surfaceWidth = widthAnchor.constraint(equalToConstant: size.width)
            surfaceHeight = heightAnchor.constraint(equalToConstant: size.height)
            surfaceWidth?.isActive = true; surfaceHeight?.isActive = true
        }
        surfaceWidth?.constant = size.width; surfaceHeight?.constant = size.height
        messageWidth?.constant = min(440, max(1, (visibleSize ?? size).width - 48))
        setFrameSize(size)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
