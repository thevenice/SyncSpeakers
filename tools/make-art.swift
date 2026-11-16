// Builds README art:
//   swift tools/make-art.swift crop <in.jpg> <out.png>   trim a window capture to the window, round its corners
//   swift tools/make-art.swift banner <out.png>          1280×640 banner using assets/icon.png and assets/screenshot-main.png
import AppKit

func bitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func cgImage(_ path: String) -> CGImage {
    NSImage(contentsOfFile: path)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

/// The window is the big block of neutral dark grey; wallpaper around it is black, red or orange.
func crop(_ inPath: String, _ outPath: String) {
    let img = cgImage(inPath)
    let src = NSBitmapImageRep(cgImage: img)
    let w = src.pixelsWide, h = src.pixelsHigh
    func isWindow(_ x: Int, _ y: Int) -> Bool {
        guard let c = src.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
        let r = c.redComponent * 255, g = c.greenComponent * 255, b = c.blueComponent * 255
        return (18...60).contains(r) && abs(r - g) < 10 && abs(r - b) < 10
    }
    func colHit(_ x: Int) -> Bool { (0..<h).filter { isWindow(x, $0) }.count > h / 2 }
    func rowHit(_ y: Int) -> Bool { (0..<w).filter { isWindow($0, y) }.count > w / 2 }
    let x0 = (0..<w).first(where: colHit)!, x1 = (0..<w).last(where: colHit)!
    let y0 = (0..<h).first(where: rowHit)!, y1 = (0..<h).last(where: rowHit)!
    let top = y0 + 1, left = x0 + 1, right = x1 - 1, bottom = y1 - 1
    let cw = right - left + 1, ch = bottom - top + 1
    let out = bitmap(cw, ch)
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    let ctx = NSGraphicsContext.current!.cgContext
    let rect = CGRect(x: 0, y: 0, width: cw, height: ch)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 28, cornerHeight: 28, transform: nil))
    ctx.clip()
    // CG origin is bottom-left; the source crop is measured from the top.
    let sub = img.cropping(to: CGRect(x: left, y: top, width: cw, height: ch))!
    ctx.draw(sub, in: rect)
    NSGraphicsContext.current = nil
    save(out, outPath)
    print("cropped \(w)x\(h) -> \(cw)x\(ch)")
}

func banner(_ outPath: String) {
    let W = 1280, H = 640
    let rep = bitmap(W, H)
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let space = CGColorSpaceCreateDeviceRGB()
    let bg = CGGradient(colorsSpace: space, colors: [
        NSColor(red: 0.16, green: 0.07, blue: 0.42, alpha: 1).cgColor,
        NSColor(red: 0.25, green: 0.18, blue: 0.80, alpha: 1).cgColor,
        NSColor(red: 0.06, green: 0.50, blue: 0.86, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])

    // Faint concentric waves behind everything, echoing the icon.
    ctx.setLineCap(.round)
    let wc = CGPoint(x: 330, y: 330)
    for (i, r) in stride(from: 180.0, through: 900.0, by: 120.0).enumerated() {
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(max(0.02, 0.10 - Double(i) * 0.012)).cgColor)
        ctx.setLineWidth(14)
        ctx.addArc(center: wc, radius: r, startAngle: -.pi / 4, endAngle: .pi / 4, clockwise: false)
        ctx.strokePath()
    }

    // App screenshot on the right, tilted slightly, with a shadow.
    let shot = cgImage("assets/screenshot-main.png")
    let sw: CGFloat = 600
    let sh = sw * CGFloat(shot.height) / CGFloat(shot.width)
    ctx.saveGState()
    ctx.translateBy(x: 955, y: 300)
    ctx.rotate(by: 0.035)
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: NSColor.black.withAlphaComponent(0.55).cgColor)
    ctx.draw(shot, in: CGRect(x: -sw / 2, y: -sh / 2, width: sw, height: sh))
    ctx.restoreGState()

    // Icon + text on the left.
    let icon = cgImage("assets/icon.png")
    ctx.draw(icon, in: CGRect(x: 52, y: 352, width: 210, height: 210))

    func text(_ s: String, _ font: NSFont, _ color: NSColor, _ x: CGFloat, _ y: CGFloat, kern: CGFloat = 0) {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern]).draw(at: NSPoint(x: x, y: y))
    }
    text("SyncSpeakers", .systemFont(ofSize: 72, weight: .heavy), .white, 76, 252, kern: -1.5)
    text("Whole-house audio from one Mac.", .systemFont(ofSize: 31, weight: .semibold), NSColor.white.withAlphaComponent(0.95), 80, 200)
    text("Any app  ·  every speaker  ·  every Mac  ·  in sync", .systemFont(ofSize: 21, weight: .medium),
         NSColor.white.withAlphaComponent(0.75), 81, 158)

    // Little pills.
    var px: CGFloat = 80
    for label in ["Wi-Fi", "Bluetooth", "Built-in & USB", "Open source"] {
        let font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        let size = (label as NSString).size(withAttributes: [.font: font])
        let r = CGRect(x: px, y: 86, width: size.width + 28, height: 36)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 18, cornerHeight: 18, transform: nil))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        ctx.fillPath()
        text(label, font, .white, px + 14, 93)
        px += r.width + 10
    }
    NSGraphicsContext.current = nil
    save(rep, outPath)
    print("banner \(W)x\(H)")
}

let a = CommandLine.arguments
switch a[1] {
case "crop": crop(a[2], a[3])
case "banner": banner(a[2])
default: print("usage: make-art crop <in> <out> | banner <out>")
}
