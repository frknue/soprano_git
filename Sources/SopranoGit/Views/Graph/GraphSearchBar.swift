import AppKit

/// The strip above the graph while searching: a `SearchField` and the `3 / 17`
/// match counter (SF Pro 11 tabular), with a hairline below.
final class GraphSearchBar: NSView {
    static let height: CGFloat = 38

    let searchField: SearchField
    private let countLabel = NSTextField(labelWithString: "")
    private let rule = ChromeRuleView(axis: .horizontal)
    private var theme: AppTheme
    private var countText = ""

    init(theme: AppTheme) {
        self.theme = theme
        searchField = SearchField(placeholder: "Search commits: message, author, sha", theme: theme, hint: "esc")
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.height))
        wantsLayer = true
        for view in [searchField, countLabel, rule] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),
            countLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 10),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            countLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: Chrome.hairline),
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
        restyle()
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        searchField.apply(theme: theme)
        restyle()
    }

    private func restyle() {
        let colors = theme.colors
        layer?.backgroundColor = colors.bgBase.cgColor
        rule.color = colors.borderSubtle
        let color = countText == "0 / 0" ? colors.danger : colors.textMuted
        countLabel.setChromeText(countText, font: ChromeFont.count, color: color)
    }
}
