import AppKit

/// The strip above the graph while searching: a `RetroSearchField` and the `3 / 17`
/// match counter, with a hairline below.
final class GraphSearchBar: NSView {
    static let height: CGFloat = 38

    let searchField: RetroSearchField
    private let countLabel = NSTextField(labelWithString: "")
    private let rule = NSView()
    private var theme: AppTheme
    private var countText = ""
    private var hasMatches = false

    init(theme: AppTheme) {
        self.theme = theme
        searchField = RetroSearchField(placeholder: "Search commits: message, author, sha", theme: theme, hint: "esc")
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.height))
        wantsLayer = true
        for view in [searchField, countLabel, rule] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        rule.wantsLayer = true
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),
            countLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 10),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            countLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: Retro.hairline),
        ])
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var field: NSTextField { searchField.field }

    /// The counter text shown (tests).
    var countString: String { countText }

    /// `current` is 1-based; nil = no current match yet. Empty without a query.
    func setCount(current: Int?, total: Int, hasQuery: Bool) {
        if !hasQuery {
            countText = ""
        } else if total == 0 {
            countText = "0 / 0"
        } else {
            countText = "\(current ?? 0) / \(total)"
        }
        hasMatches = total > 0
        restyle()
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        searchField.apply(theme: theme)
        restyle()
    }

    private func restyle() {
        let colors = theme.colors
        layer?.backgroundColor = colors.bgPanel.cgColor
        rule.layer?.backgroundColor = colors.borderSubtle.cgColor
        let color = countText == "0 / 0" ? colors.danger : (hasMatches ? colors.yellow : colors.textMuted)
        countLabel.setRetroText(countText, color: color, size: 11)
    }
}
