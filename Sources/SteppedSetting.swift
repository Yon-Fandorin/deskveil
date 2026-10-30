import AppKit

/// A shared presentation for discrete settings; the owner maps indices to values.
final class SteppedSetting: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let minimumLabel = NSTextField(labelWithString: "")
    private let maximumLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private var choices: [String] = []
    private(set) var selectedIndex = 0
    var onChange: ((Int) -> Void)?
    var isEnabled = true {
        didSet {
            slider.isEnabled = isEnabled
            titleLabel.textColor = isEnabled ? .labelColor : .disabledControlTextColor
            valueLabel.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        }
    }

    init(title: String, choices: [String], id: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13)
        valueLabel.font = .systemFont(ofSize: 13, weight: .medium)
        valueLabel.alignment = .right
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.setAccessibilityIdentifier(id + "-value")
        slider.minValue = 0
        slider.isContinuous = true
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        slider.target = self; slider.action = #selector(changed)
        slider.setAccessibilityIdentifier(id)
        slider.setAccessibilityLabel(title)
        for label in [minimumLabel, maximumLabel, detailLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        maximumLabel.alignment = .right
        let heading = NSStackView(views: [titleLabel, NSView(), valueLabel])
        heading.orientation = .horizontal; heading.alignment = .firstBaseline
        let ends = NSStackView(views: [minimumLabel, NSView(), maximumLabel])
        ends.orientation = .horizontal; ends.alignment = .firstBaseline
        let content = NSStackView(views: [heading, slider, ends, detailLabel])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 6
        for view in content.arrangedSubviews { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
        update(choices: choices, selectedIndex: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(choices: [String], selectedIndex: Int, value: String? = nil, detail: String = "") {
        precondition(choices.count >= 2)
        if self.choices != choices {
            self.choices = choices
            slider.maxValue = Double(choices.count - 1)
            slider.numberOfTickMarks = choices.count
            minimumLabel.stringValue = choices.first!
            maximumLabel.stringValue = choices.last!
        }
        self.selectedIndex = min(choices.count - 1, max(0, selectedIndex))
        slider.integerValue = self.selectedIndex
        valueLabel.stringValue = value ?? choices[self.selectedIndex]
        slider.setAccessibilityValueDescription(valueLabel.stringValue)
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
    }

    @objc private func changed() {
        let index = min(choices.count - 1, max(0, Int(slider.doubleValue.rounded())))
        slider.integerValue = index
        guard index != selectedIndex else { return }
        selectedIndex = index
        valueLabel.stringValue = choices[index]
        slider.setAccessibilityValueDescription(valueLabel.stringValue)
        onChange?(index)
    }
}
