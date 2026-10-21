import AppKit
import SopranoGitCore

/// Metrics of the commit graph (ARCHITECTURE.md "Layout and visual design").
enum GraphMetrics {
    static let rowHeight: CGFloat = 28
    static let headerHeight: CGFloat = 28
    static let laneSpacing: CGFloat = 14
    static let laneInset: CGFloat = 9
    static let lineWidth: CGFloat = 2
    /// Text inset of every cell and header title.
    static let cellPadding: CGFloat = 12
    /// Commit node diameter.
    static let nodeSize: CGFloat = 8
    /// Stroke-centre radius of the HEAD ring (stroke 1.5).
    static let headRingRadius: CGFloat = 7
    static let headRingWidth: CGFloat = 1.5
    /// Dashed lines (working copy, stashes): on, off.
    static let dash: [CGFloat] = [4, 3]
    /// The working-copy node's dashed ring: on, off.
    static let workingCopyNodeDash: [CGFloat] = [2.5, 2]
    static var dashPeriod: CGFloat { dash.reduce(0, +) }

    static func laneX(_ lane: Int) -> CGFloat {
        laneInset + (CGFloat(lane) + 0.5) * laneSpacing
    }

    /// Graph column width for `lanes` lanes, before clamping.
    static func graphWidth(lanes: Int) -> CGFloat {
        laneInset * 2 + CGFloat(max(1, lanes)) * laneSpacing
    }

    /// Automatic width range of the graph column (it follows the widest row); users may drag it wider.
    static let graphWidthRange: ClosedRange<CGFloat> = 64 ... 280
}

/// Everything the graph draws with for one theme: the lane colors, text attributes,
/// tinted symbol images and measured pill widths. Rebuilt on theme change; cells only
/// read from it, so drawing a row allocates nothing new once warm.
@MainActor
final class GraphStyle {
    let theme: AppTheme
    /// `theme.graphLanes`: a graphite trunk and seven hues, never the accent.
    let lanes: [NSColor]
    let laneCGColors: [CGColor]

    /// Commit message: SF Pro 12 ink.
    let messageAttributes: [NSAttributedString.Key: Any]
    /// Merge and stash messages: SF Pro 12 muted.
    let mergeMessageAttributes: [NSAttributedString.Key: Any]
    /// Author and date: SF Pro 11 tabular, muted.
    let metaAttributes: [NSAttributedString.Key: Any]
    /// Author and date on the selected row: ink.
    let selectedMetaAttributes: [NSAttributedString.Key: Any]
    /// Short SHA: SF Mono 11, muted.
    let shaAttributes: [NSAttributedString.Key: Any]
    /// Short SHA on the selected row: ink.
    let selectedShaAttributes: [NSAttributedString.Key: Any]
    /// The working-copy row's `// WIP` label: SF Pro 12 Semibold ink.
    let wipAttributes: [NSAttributedString.Key: Any]
    /// Ref pill face: SF Pro 11 Medium.
    let pillFont: NSFont
    /// Line box height of the pill face, for vertical centering.
    let pillLineHeight: CGFloat
    /// Lane color at 10 %: pill fill.
    let laneTints: [NSColor]
    /// HEAD pill: the ink button's fill and label.
    let headPillFill: NSColor
    let headPillInk: NSColor
    /// HEAD ring around the node.
    let headRingCGColor: CGColor
    /// Working-copy node and its dashed edge.
    let workingCopyCGColor: CGColor
    /// Rail of search hits that are not the current one.
    let matchMutedColor: NSColor
    /// Search text highlight behind the matched characters (unselected rows).
    let matchTextBackground: NSColor
    /// Matched characters on the selected row: `matchOnSelection`, Semibold.
    let matchOnSelection: NSColor
    let matchFont: NSFont

    private var symbolCache: [SymbolKey: NSImage] = [:]
    private var textWidthCache: [String: CGFloat] = [:]
    private var pillAttributeCache: [ObjectIdentifier: [NSAttributedString.Key: Any]] = [:]
    private var countAttributeCache: [ObjectIdentifier: [NSAttributedString.Key: Any]] = [:]

    private struct SymbolKey: Hashable {
        let name: String
        let pointSize: CGFloat
        /// Colors come from the theme or this style (stored instances), so identity is stable.
        let color: ObjectIdentifier
    }

    init(theme: AppTheme) {
        self.theme = theme
        let colors = theme.colors
        lanes = theme.graphLanes
        laneCGColors = lanes.map(\.cgColor)

        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let meta = ChromeFont.count
        let sha = ChromeFont.monoSmall
        messageAttributes = [.font: ChromeFont.label, .foregroundColor: colors.textPrimary, .paragraphStyle: truncating]
        mergeMessageAttributes = [.font: ChromeFont.label, .foregroundColor: colors.textMuted, .paragraphStyle: truncating]
        metaAttributes = [.font: meta, .foregroundColor: colors.textMuted, .paragraphStyle: truncating]
        selectedMetaAttributes = [.font: meta, .foregroundColor: colors.textPrimary, .paragraphStyle: truncating]
        shaAttributes = [.font: sha, .foregroundColor: colors.textMuted, .paragraphStyle: truncating]
        selectedShaAttributes = [.font: sha, .foregroundColor: colors.textPrimary, .paragraphStyle: truncating]
        wipAttributes = [
            .font: ChromeFont.sans(size: 12, weight: .semibold), .foregroundColor: colors.textPrimary,
            .paragraphStyle: truncating,
        ]
        pillFont = ChromeFont.sans(size: 11, weight: .medium)
        pillLineHeight = ceil(pillFont.ascender - pillFont.descender)
        laneTints = lanes.map { $0.withAlphaComponent(0.10) }
        headPillFill = colors.inkButtonFill
        headPillInk = colors.inkButtonLabel
        headRingCGColor = colors.textPrimary.cgColor
        workingCopyCGColor = colors.textMuted.cgColor
        matchMutedColor = colors.yellow.withAlphaComponent(0.5)
        matchTextBackground = colors.yellow.withAlphaComponent(0.32)
        matchOnSelection = colors.matchOnSelection
        matchFont = ChromeFont.sans(size: 12, weight: .semibold)
    }

    /// Pill text in `color` (SF Pro 11 Medium, truncating), cached per color.
    func pillAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        let key = ObjectIdentifier(color)
        if let attributes = pillAttributeCache[key] { return attributes }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: pillFont, .foregroundColor: color, .paragraphStyle: paragraph]
        pillAttributeCache[key] = attributes
        return attributes
    }

    /// Working-copy file counts in `color` (SF Pro 11 Semibold, tabular), cached per color.
    func countAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        let key = ObjectIdentifier(color)
        if let attributes = countAttributeCache[key] { return attributes }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: ChromeFont.sans(size: 11, weight: .semibold, tabular: true), .foregroundColor: color,
        ]
        countAttributeCache[key] = attributes
        return attributes
    }

    var colors: ThemeColors { theme.colors }

    func laneColor(_ lane: Int) -> NSColor { lanes[lane % lanes.count] }
    func laneCGColor(_ lane: Int) -> CGColor { laneCGColors[lane % laneCGColors.count] }
    func laneTint(_ lane: Int) -> NSColor { laneTints[lane % laneTints.count] }

    /// Search hit rail and text highlight.
    var matchColor: NSColor { colors.yellow }

    /// An SF Symbol tinted `color`, cached per (name, size, color). Pass theme colors
    /// or this style's stored colors, never freshly derived ones.
    func symbol(_ name: String, color: NSColor, pointSize: CGFloat = 11) -> NSImage? {
        let key = SymbolKey(name: name, pointSize: pointSize, color: ObjectIdentifier(color))
        if let image = symbolCache[key] { return image }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return nil }
        symbolCache[key] = image
        return image
    }

    /// Width of `text` in the pill face (cached; ref names repeat on every redraw).
    func pillTextWidth(_ text: String) -> CGFloat {
        if let width = textWidthCache[text] { return width }
        let width = ceil((text as NSString).size(withAttributes: [.font: pillFont]).width)
        textWidthCache[text] = width
        return width
    }
}
