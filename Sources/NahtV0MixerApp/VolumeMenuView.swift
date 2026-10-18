import AppKit

@MainActor
final class VolumeMenuView: NSView {
    private final class TrackingSlider: NSSlider {
        private(set) var isTrackingUserInteraction = false

        override func mouseDown(with event: NSEvent) {
            isTrackingUserInteraction = true
            defer { isTrackingUserInteraction = false }
            super.mouseDown(with: event)
        }
    }

    private let title: String
    private let muteLabel: String
    private let unmuteLabel: String
    private let onChange: (Double) -> Void
    private let onMute: () -> Void
    private let onReset: (() -> Void)?
    private let muteButton = NSButton()
    private let resetButton = NSButton()
    private let slider: TrackingSlider
    private let percentageLabel: NSTextField
    private var lastSubmittedValue: Double?

    init(title: String, image: NSImage?, muteLabel: String, unmuteLabel: String, resetLabel: String,
         onMute: @escaping () -> Void, onReset: (() -> Void)? = nil,
         onChange: @escaping (Double) -> Void) {
        self.title = title
        self.muteLabel = muteLabel
        self.unmuteLabel = unmuteLabel
        self.onChange = onChange
        self.onMute = onMute
        self.onReset = onReset
        self.slider = TrackingSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
        self.percentageLabel = NSTextField(labelWithString: "—")
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 68))

        let icon = NSImageView(image: image ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configure(muteButton, symbol: "speaker.wave.2.fill", label: muteLabel, action: #selector(mute))
        configure(resetButton, symbol: "arrow.counterclockwise", label: resetLabel, action: #selector(reset))
        resetButton.isHidden = onReset == nil
        let heading = NSStackView(views: [icon, label, resetButton, muteButton])
        heading.alignment = .centerY
        heading.spacing = 8
        heading.setHuggingPriority(.defaultLow, for: .horizontal)

        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.isContinuous = true
        slider.controlSize = .large
        slider.setAccessibilityLabel(title)

        percentageLabel.alignment = .right
        percentageLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        percentageLabel.textColor = .secondaryLabelColor
        percentageLabel.setAccessibilityElement(false)

        addSubview(heading)
        addSubview(slider)
        addSubview(percentageLabel)
        autoresizingMask = [.width]
        slider.translatesAutoresizingMaskIntoConstraints = false
        heading.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        percentageLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            slider.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4),
            slider.trailingAnchor.constraint(equalTo: percentageLabel.leadingAnchor, constant: -8),
            percentageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            percentageLabel.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            percentageLabel.widthAnchor.constraint(equalToConstant: 40),
            slider.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6)
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        updateAccessibilityValue()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 320, height: 68)
    }

    func update(value: Double?, enabled: Bool, muted: Bool?, muteEnabled: Bool, resetEnabled: Bool) {
        muteButton.state = muted == true ? .on : .off
        let actionLabel = muted == true ? unmuteLabel : muteLabel
        muteButton.toolTip = actionLabel
        muteButton.setAccessibilityLabel("\(actionLabel): \(title)")
        muteButton.image = NSImage(systemSymbolName: muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                  accessibilityDescription: nil)
        muteButton.isEnabled = muteEnabled && muted != nil
        resetButton.isEnabled = resetEnabled
        guard !slider.isTrackingUserInteraction else { return }

        if let value, value.isFinite {
            let clampedValue = min(max(value, 0), 1)
            slider.doubleValue = clampedValue
            lastSubmittedValue = clampedValue
            percentageLabel.stringValue = percentage(clampedValue)
        } else {
            lastSubmittedValue = nil
            percentageLabel.stringValue = "—"
        }

        let isAvailable = value?.isFinite == true && enabled
        slider.isEnabled = isAvailable
        percentageLabel.textColor = isAvailable ? .secondaryLabelColor : .disabledControlTextColor
        updateAccessibilityValue()
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard sender.isEnabled else { return }

        guard let value = normalizedValue(sender.doubleValue) else {
            percentageLabel.stringValue = "—"
            updateAccessibilityValue()
            return
        }
        percentageLabel.stringValue = percentage(value)
        updateAccessibilityValue()
        // AppKit may send continuous actions while the mouse is stationary.
        // Repeating the same audio write also repeats device/process discovery.
        guard value != lastSubmittedValue else { return }
        lastSubmittedValue = value
        onChange(value)
    }

    private func updateAccessibilityValue() {
        let value = slider.isEnabled ? normalizedValue(slider.doubleValue).map(percentage) ?? "—" : percentageLabel.stringValue
        setAccessibilityValue(value)
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.bezelStyle = .inline
        button.isBordered = false
        button.controlSize = .regular
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel("\(label): \(title)")
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    @objc private func mute() { if muteButton.isEnabled { onMute() } }
    @objc private func reset() { if resetButton.isEnabled { onReset?() } }

    private func normalizedValue(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    private func percentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
