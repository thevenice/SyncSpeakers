// Draws the SyncSpeakers icon: one source broadcasting in sync to speakers on both sides.
// Usage: swift tools/make-icon.swift <out.png> [size]
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "icon.png"
let S = CGFloat(args.count > 2 ? Double(args[2])! : 1024)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let cg = NSGraphicsContext.current!.cgContext
func u(_ v: CGFloat) -> CGFloat { v * S / 1024 }

// macOS icon grid: 824pt rounded square centred in 1024 with drop shadow.
let inset = u(100)
let tile = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let shape = CGPath(roundedRect: tile, cornerWidth: u(185), cornerHeight: u(185), transform: nil)

cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -u(12)), blur: u(28), color: NSColor.black.withAlphaComponent(0.35).cgColor)
cg.addPath(shape); cg.setFillColor(NSColor.black.cgColor); cg.fillPath()
cg.restoreGState()

cg.saveGState()
cg.addPath(shape); cg.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(red: 0.42, green: 0.20, blue: 0.95, alpha: 1).cgColor,
    NSColor(red: 0.10, green: 0.62, blue: 0.95, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
// soft top highlight
let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(hl, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])

let c = CGPoint(x: S / 2, y: S / 2)
let white = NSColor.white.cgColor

// Waves going out both ways, fading with distance.
cg.setLineCap(.round)
for (i, r) in [u(150), u(232), u(314)].enumerated() {
    cg.setStrokeColor(NSColor.white.withAlphaComponent([0.95, 0.75, 0.5][i]).cgColor)
    cg.setLineWidth(u(40))
    let span = CGFloat.pi / 4.2
    for base in [CGFloat(0), .pi] {
        cg.addArc(center: c, radius: r, startAngle: base - span, endAngle: base + span, clockwise: false)
        cg.strokePath()
    }
}

// Source: a speaker cone seen from the front.
cg.setFillColor(white)
cg.fillEllipse(in: CGRect(x: c.x - u(92), y: c.y - u(92), width: u(184), height: u(184)))
cg.setFillColor(NSColor(red: 0.27, green: 0.38, blue: 0.95, alpha: 1).cgColor)
cg.fillEllipse(in: CGRect(x: c.x - u(52), y: c.y - u(52), width: u(104), height: u(104)))
cg.setFillColor(white)
cg.fillEllipse(in: CGRect(x: c.x - u(20), y: c.y - u(20), width: u(40), height: u(40)))
cg.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
