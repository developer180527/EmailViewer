import AppKit

/// Pulsing placeholder rows shown during the first inbox load (instead of a spinner).
final class SkeletonView: NSView {

    private let rowHeight: CGFloat = 72

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        buildRows()
    }
    required init?(coder: NSCoder) { fatalError() }

    func startAnimating() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.45
        pulse.toValue   = 1.0
        pulse.duration  = 0.85
        pulse.autoreverses = true
        pulse.repeatCount  = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(pulse, forKey: "pulse")
    }

    func stopAnimating() { layer?.removeAnimation(forKey: "pulse") }

    private func buildRows() {
        var top: NSLayoutYAxisAnchor = topAnchor
        for _ in 0..<8 {
            let row = makeRow()
            addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: top),
                row.leadingAnchor.constraint(equalTo: leadingAnchor),
                row.trailingAnchor.constraint(equalTo: trailingAnchor),
                row.heightAnchor.constraint(equalToConstant: rowHeight),
            ])
            top = row.bottomAnchor
        }
    }

    private func makeRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let avatar = bar(); avatar.layer?.cornerRadius = 17
        let line1 = bar(); let line2 = bar(); let line3 = bar()
        [avatar, line1, line2, line3].forEach { row.addSubview($0) }

        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 34),
            avatar.heightAnchor.constraint(equalToConstant: 34),
            avatar.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            avatar.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            line1.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 12),
            line1.topAnchor.constraint(equalTo: row.topAnchor, constant: 17),
            line1.heightAnchor.constraint(equalToConstant: 11),
            line1.widthAnchor.constraint(equalToConstant: 120),

            line2.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 12),
            line2.topAnchor.constraint(equalTo: line1.bottomAnchor, constant: 9),
            line2.heightAnchor.constraint(equalToConstant: 10),
            line2.widthAnchor.constraint(equalToConstant: 210),

            line3.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 12),
            line3.topAnchor.constraint(equalTo: line2.bottomAnchor, constant: 7),
            line3.heightAnchor.constraint(equalToConstant: 10),
            line3.widthAnchor.constraint(equalToConstant: 150),
        ])
        return row
    }

    private func bar() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.cornerRadius = 5
        v.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        return v
    }

    override func updateLayer() {
        // Re-resolve the dynamic placeholder color on light/dark switch.
        subviews.forEach { row in
            row.subviews.forEach { $0.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor }
        }
    }
}
