import AppKit
import SopranoGitCore

/// Metrics of the commit graph (ARCHITECTURE.md "Layout and visual design").
enum GraphMetrics {
    static let rowHeight: CGFloat = 28
    static let headerHeight: CGFloat = 28
    static let laneSpacing: CGFloat = 14
    static let laneInset: CGFloat = 6
    static let lineWidth: CGFloat = 2
    static let cellPadding: CGFloat = 8
    /// Dashed lines (working copy, stashes): on, off.
    static let dash: [CGFloat] = [4, 3]
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

/// Everything the graph draws with for one theme: the lane palette, text attributes,
/// tinted symbol images and measured pill widths. Rebuilt on theme change; cells only
/// read from it, so drawing a row allocates nothing new once warm.
@MainActor
final class GraphStyle {
    let theme: AppTheme
    let lanes: [NSColor]
    let laneCGColors: [CGColor]
    let laneGlowColors: [CGColor]

    let messageAttributes: [NSAttributedString.Key: Any]
    let mergeMessageAttributes: [NSAttributedString.Key: Any]
    let mutedAttributes: [NSAttributedString.Key: Any]
    let wipAttributes: [NSAttributedString.Key: Any]
    let pillFont: NSFont
    /// Line box height of the pill face, for vertical centering.
    let pillLineHeight: CGFloat
    /// Lane color at α0.18: unlit pill fill.
    let laneTints: [NSColor]
    /// Rail of search hits that are not the current one.
    let matchMutedColor: NSColor
    /// Search text highlight behind the matched characters.
    let matchTextBackground: NSColor

    private var symbolCache: [SymbolKey: NSImage] = [:]
    private var textWidthCache: [String: CGFloat] = [:]
    private var pillAttributeCache: [ObjectIdentifier: [NSAttributedString.Key: Any]] = [:]
    private var countAttributeCache: [ObjectIdentifier: [NSAttributedString.Key: Any]] = [:]

    private struct SymbolKey: Hashable {
        let name: String
        let pointSize: CGFloat
        /// Colors come from the theme (stored instances), so identity is stable.
        let color: ObjectIdentifier
    }

    init(theme: AppTheme) {
        self.theme = theme
        let colors = theme.colors
        lanes = Self.palette(for: theme)
        laneCGColors = lanes.map(\.cgColor)
        laneGlowColors = lanes.map { $0.withAlphaComponent(0.75).cgColor }

        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        messageAttributes = [.font: RetroFont.body(12), .foregroundColor: colors.textPrimary, .paragraphStyle: truncating]
        mergeMessageAttributes = [.font: RetroFont.body(12), .foregroundColor: colors.textMuted, .paragraphStyle: truncating]
        mutedAttributes = [.font: RetroFont.body(11), .foregroundColor: colors.textMuted, .paragraphStyle: truncating]
        wipAttributes = [.font: RetroFont.body(12, weight: .semibold), .foregroundColor: colors.textPrimary, .paragraphStyle: truncating]
        pillFont = RetroFont.display(11)
        pillLineHeight = ceil(pillFont.ascender - pillFont.descender)
        laneTints = lanes.map { $0.withAlphaComponent(0.18) }
        matchMutedColor = colors.yellow.withAlphaComponent(0.5)
        matchTextBackground = colors.yellow.withAlphaComponent(0.32)
    }

    /// Pill text in `color` (display face, tracked, truncating), cached per color.
    func pillAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        let key = ObjectIdentifier(color)
        if let attributes = pillAttributeCache[key] { return attributes }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: pillFont, .foregroundColor: color, .kern: RetroText.tracking, .paragraphStyle: paragraph,
        ]
        pillAttributeCache[key] = attributes
        return attributes
    }

    /// Working-copy file counts in `color` (body 11 semibold), cached per color.
    func countAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        let key = ObjectIdentifier(color)
        if let attributes = countAttributeCache[key] { return attributes }
        let attributes: [NSAttributedString.Key: Any] = [.font: RetroFont.body(11, weight: .semibold), .foregroundColor: color]
        countAttributeCache[key] = attributes
        return attributes
    }

    var colors: ThemeColors { theme.colors }

    func laneColor(_ lane: Int) -> NSColor { lanes[lane % lanes.count] }
    func laneCGColor(_ lane: Int) -> CGColor { laneCGColors[lane % laneCGColors.count] }
    func laneGlow(_ lane: Int) -> CGColor { laneGlowColors[lane % laneGlowColors.count] }

    /// Search hit rail and text highlight.
    var matchColor: NSColor { colors.yellow }

    /// An SF Symbol tinted `color`, cached per (name, size, color). Pass theme colors
    /// (stored instances), never freshly derived ones.
    func symbol(_ name: String, color: NSColor, pointSize: CGFloat = 9) -> NSImage? {
        let key = SymbolKey(name: name, pointSize: pointSize, color: ObjectIdentifier(color))
        if let image = symbolCache[key] { return image }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
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
        let width = ceil((text as NSString).size(withAttributes: [.font: pillFont, .kern: RetroText.tracking]).width)
        textWidthCache[text] = width
        return width
    }

    // MARK: - Palette

    /// 8–10 distinct, vivid lane colors from the theme: its accent and signal colors
    /// first, then the terminal's magenta and bright colors; near-duplicates and colors
    /// that vanish on the panel are dropped. Themes with fewer distinct colors are
    /// topped up with hue-rotated variants of their own colors.
    static func palette(for theme: AppTheme) -> [NSColor] {
        let colors = theme.colors
        let terminal = theme.terminalColors
        let candidates: [NSColor] = [
            colors.accent, colors.blue, colors.success, colors.accentStrong, colors.cyan, terminal.magenta,
            colors.yellow, colors.danger, terminal.brightMagenta, terminal.brightBlue, terminal.brightGreen,
            terminal.brightCyan, terminal.brightYellow, terminal.brightRed, terminal.red, terminal.green,
            terminal.blue, terminal.cyan,
        ]
        let panel = rgb(colors.bgPanel)
        var chosen: [NSColor] = []
        func addIfDistinct(_ color: NSColor, threshold: Double) {
            let value = rgb(color)
            guard chosen.count < 10, distance(value, panel) > 0.28,
                  chosen.allSatisfy({ distance(rgb($0), value) > threshold })
            else { return }
            chosen.append(color)
        }
        for color in candidates where saturation(color) > 0.18 {
            addIfDistinct(color, threshold: 0.2)
        }
        if chosen.isEmpty { chosen = [colors.accent] }
        let seeds = chosen
        for offset in [0.5, 0.25, 0.75, 0.125, 0.625, 0.375, 0.875] where chosen.count < 8 {
            for seed in seeds where chosen.count < 8 {
                let srgb = seed.usingColorSpace(.sRGB) ?? seed
                let hue = (srgb.hueComponent + offset).truncatingRemainder(dividingBy: 1)
                let variant = NSColor(
                    hue: hue,
                    saturation: max(srgb.saturationComponent, 0.5),
                    brightness: max(srgb.brightnessComponent, 0.75),
                    alpha: 1
                )
                addIfDistinct(variant, threshold: 0.2)
            }
        }
        return chosen
    }

    private static func rgb(_ color: NSColor) -> (Double, Double, Double) {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return (Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
    }

    private static func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let red = a.0 - b.0, green = a.1 - b.1, blue = a.2 - b.2
        return (red * red * 0.3 + green * green * 0.59 + blue * blue * 0.11).squareRoot() * 1.6
    }

    private static func saturation(_ color: NSColor) -> Double {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return Double(srgb.saturationComponent)
    }
}
