import AppKit

enum InboxFilter: CaseIterable {
    case all, unread, starred

    var title: String {
        switch self {
        case .all:     return "All"
        case .unread:  return "Unread"
        case .starred: return "Starred"
        }
    }

    /// Whether an email passes this filter.
    func matches(_ email: Email) -> Bool {
        switch self {
        case .all:     return true
        case .unread:  return !email.isRead
        case .starred: return email.isStarred
        }
    }
}

/// A row of pill chips for quick inbox filtering.
final class FilterBar: NSView {

    var onChange: ((InboxFilter) -> Void)?
    private(set) var selected: InboxFilter = .all
    private var chips: [InboxFilter: ChipButton] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 6
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for filter in InboxFilter.allCases {
            let chip = ChipButton(title: filter.title)
            chip.isSelectedChip = (filter == selected)
            chip.onClick = { [weak self] in self?.select(filter) }
            chips[filter] = chip
            stack.addArrangedSubview(chip)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func select(_ filter: InboxFilter) {
        guard filter != selected else { return }
        selected = filter
        chips.forEach { $0.value.isSelectedChip = ($0.key == filter) }
        onChange?(filter)
    }
}

/// A single selectable pill. Re-styles itself for selection state and light/dark.
final class ChipButton: NSView {

    var onClick: (() -> Void)?
    var isSelectedChip = false { didSet { applyStyle() } }

    private let label = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 0.5

        label.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.alignment = .center
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
        ])
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick?() }

    // Treat the whole pill (incl. the label) as one click target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func viewDidChangeEffectiveAppearance() { applyStyle() }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isSelectedChip {
                layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                layer?.borderColor     = NSColor.controlAccentColor.cgColor
                label.textColor         = .white
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
                layer?.borderColor     = NSColor.separatorColor.cgColor
                label.textColor         = .secondaryLabelColor
            }
        }
    }
}
