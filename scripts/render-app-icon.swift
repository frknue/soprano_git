// Renders the Soprano Git app icon as a 1024×1024 PNG.
// Usage: swift scripts/render-app-icon.swift <output.png>
//
// Family look of Soprano's icon: a dark #2a2a2a rounded square, cream #8a8270 tiles and
// strokes, and exactly one glowing orange #ff7f1a "lamp". The motif is a git graph: a
// cream trunk lane with commit tiles, a branch that curves off the trunk and runs parallel
// to it, and the branch tip (HEAD) lit as the lamp.
import AppKit

let canvasSize = 1024
let canvas = CGFloat(canvasSize)

// macOS icon grid: an 824 pt body centred on the 1024 canvas, with the matching corner radius.
let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyRadius: CGFloat = 185

let background = CGColor(srgbRed: 0x2a / 255, green: 0x2a / 255, blue: 0x2a / 255, alpha: 1)
let edge = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07)
let cream = CGColor(srgbRed: 0x8a / 255, green: 0x82 / 255, blue: 0x70 / 255, alpha: 1)
let orange = CGColor(srgbRed: 1, green: 0x7f / 255, blue: 0x1a / 255, alpha: 1)

// Graph geometry, in top-left coordinates on the 1024 canvas.
let trunkX: CGFloat = 400
let branchX: CGFloat = 624
let laneWidth: CGFloat = 40
let tileSize: CGFloat = 116
let tileRadius: CGFloat = 30
let topY: CGFloat = 342
let middleY: CGFloat = 512
let bottomY: CGFloat = 682
let forkRadius: CGFloat = 100

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: render-app-icon.swift <output.png>\n".utf8))
    exit(2)
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

guard
    let context = CGContext(
        data: nil,
        width: canvasSize,
        height: canvasSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
else {
    FileHandle.standardError.write(Data("render-app-icon: could not create a bitmap context.\n".utf8))
    exit(1)
}

// Draw in top-left coordinates so the geometry above reads like a screen layout.
context.translateBy(x: 0, y: canvas)
context.scaleBy(x: 1, y: -1)

func tileRect(centerX: CGFloat, centerY: CGFloat) -> CGRect {
    CGRect(x: centerX - tileSize / 2, y: centerY - tileSize / 2, width: tileSize, height: tileSize)
}

func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Body with a soft drop shadow beneath it.
let bodyPath = roundedPath(bodyRect, radius: bodyRadius)
context.saveGState()
// Shadow offsets ignore the flipped CTM, so a negative height drops the shadow downwards.
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: CGColor(gray: 0, alpha: 0.32))
context.addPath(bodyPath)
context.setFillColor(background)
context.fillPath()
context.restoreGState()

// Hairline edge, as on Soprano's icon.
context.saveGState()
context.addPath(roundedPath(bodyRect.insetBy(dx: 1.5, dy: 1.5), radius: bodyRadius - 1.5))
context.setStrokeColor(edge)
context.setLineWidth(3)
context.strokePath()
context.restoreGState()

// Everything else stays inside the body.
context.addPath(bodyPath)
context.clip()

// Lanes: the trunk, and the branch that curves off it and runs parallel up to HEAD.
let lanes = CGMutablePath()
lanes.move(to: CGPoint(x: trunkX, y: topY))
lanes.addLine(to: CGPoint(x: trunkX, y: bottomY))
lanes.move(to: CGPoint(x: trunkX, y: bottomY))
lanes.addArc(
    tangent1End: CGPoint(x: branchX, y: bottomY),
    tangent2End: CGPoint(x: branchX, y: topY),
    radius: forkRadius
)
lanes.addLine(to: CGPoint(x: branchX, y: topY))
context.saveGState()
context.addPath(lanes)
context.setStrokeColor(cream)
context.setLineWidth(laneWidth)
context.setLineCap(.round)
context.setLineJoin(.round)
context.strokePath()
context.restoreGState()

// Commit tiles: three on the trunk, one where the branch runs parallel to it.
context.setFillColor(cream)
for center in [
    CGPoint(x: trunkX, y: topY), CGPoint(x: trunkX, y: middleY), CGPoint(x: trunkX, y: bottomY),
    CGPoint(x: branchX, y: middleY),
] {
    context.addPath(roundedPath(tileRect(centerX: center.x, centerY: center.y), radius: tileRadius))
    context.fillPath()
}

// HEAD: the single glowing orange lamp at the branch tip.
let lamp = roundedPath(tileRect(centerX: branchX, centerY: topY), radius: tileRadius)
context.saveGState()
context.setShadow(offset: .zero, blur: 90, color: CGColor(srgbRed: 1, green: 0x7f / 255, blue: 0x1a / 255, alpha: 0.55))
context.addPath(lamp)
context.setFillColor(orange)
context.fillPath()
context.restoreGState()
context.saveGState()
context.setShadow(offset: .zero, blur: 28, color: CGColor(srgbRed: 1, green: 0x7f / 255, blue: 0x1a / 255, alpha: 0.45))
context.addPath(lamp)
context.setFillColor(orange)
context.fillPath()
context.restoreGState()

guard let image = context.makeImage() else {
    FileHandle.standardError.write(Data("render-app-icon: could not finish the bitmap.\n".utf8))
    exit(1)
}
let bitmap = NSBitmapImageRep(cgImage: image)
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("render-app-icon: could not encode the PNG.\n".utf8))
    exit(1)
}
do {
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try png.write(to: outputURL, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("render-app-icon: could not write \(outputURL.path): \(error)\n".utf8))
    exit(1)
}
