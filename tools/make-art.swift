// Builds README art:
//   swift tools/make-art.swift crop <in.jpg> <out.png>   trim a window capture to the window, round its corners
//   swift tools/make-art.swift banner <out.png>          1280×640 banner: icon, Mac screenshot and two phone mocks
//   swift tools/make-art.swift phones <in>... <out.png>  phone captures in a generic phone frame, side by side
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

    // Mac window on the right, tilted slightly, with a shadow.
    let shot = cgImage("assets/screenshot-main.png")
    let sw: CGFloat = 560
    let sh = sw * CGFloat(shot.height) / CGFloat(shot.width)
    ctx.saveGState()
    ctx.translateBy(x: 905, y: 372)
    ctx.rotate(by: 0.03)
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: NSColor.black.withAlphaComponent(0.55).cgColor)
    ctx.draw(shot, in: CGRect(x: -sw / 2, y: -sh / 2, width: sw, height: sh))
    ctx.restoreGState()

    // Two phones in front of the window: one just joining, one playing.
    let join = phoneMock(cgImage("assets/phone-join.png"))
    let play = phoneMock(cgImage("assets/phone-playing.png"))
    func drawPhone(_ img: CGImage, cx: CGFloat, cy: CGFloat, height: CGFloat, angle: CGFloat) {
        let w = height * CGFloat(img.width) / CGFloat(img.height)
        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy)
        ctx.rotate(by: angle)
        ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 40, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.draw(img, in: CGRect(x: -w / 2, y: -height / 2, width: w, height: height))
        ctx.restoreGState()
    }
    drawPhone(join, cx: 1030, cy: 200, height: 330, angle: -0.06)
    drawPhone(play, cx: 1165, cy: 225, height: 380, angle: 0.05)

    // Icon + text on the left.
    let icon = cgImage("assets/icon.png")
    ctx.draw(icon, in: CGRect(x: 52, y: 352, width: 210, height: 210))

    func text(_ s: String, _ font: NSFont, _ color: NSColor, _ x: CGFloat, _ y: CGFloat, kern: CGFloat = 0) {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern]).draw(at: NSPoint(x: x, y: y))
    }
    text("SyncSpeakers", .systemFont(ofSize: 72, weight: .heavy), .white, 76, 252, kern: -1.5)
    text("Whole-house audio from one Mac.", .systemFont(ofSize: 31, weight: .semibold), NSColor.white.withAlphaComponent(0.95), 80, 200)
    text("Any app  ·  every speaker  ·  every Mac  ·  every phone", .systemFont(ofSize: 21, weight: .medium),
         NSColor.white.withAlphaComponent(0.75), 81, 158)

    // Little pills.
    var px: CGFloat = 80
    for label in ["Wi-Fi", "Bluetooth", "Phones: scan to join", "Open source"] {
        let font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        let size = (label as NSString).size(withAttributes: [.font: font])
        let r = CGRect(x: px, y: 86, width: size.width + 26, height: 34)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 17, cornerHeight: 17, transform: nil))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        ctx.fillPath()
        text(label, font, .white, px + 13, 93)
        px += r.width + 9
    }
    NSGraphicsContext.current = nil
    save(rep, outPath)
    print("banner \(W)x\(H)")
}

/// A generic modern phone: dark rounded body, thin bezel, pill-shaped camera cutout, status bar.
/// `screen` is a phone-sized capture (e.g. 780×1688 at 2×).
func phoneMock(_ screen: CGImage) -> CGImage {
    let sw = CGFloat(screen.width), sh = CGFloat(screen.height)
    let bezel = sw * 0.045, W = sw + bezel * 2, H = sh + bezel * 2
    let rep = bitmap(Int(W), Int(H))
    let previous = NSGraphicsContext.current
    defer { NSGraphicsContext.current = previous }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let body = CGRect(x: 0, y: 0, width: W, height: H)
    let bodyR = W * 0.165
    // Frame: dark metal with a soft edge highlight.
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: bodyR, cornerHeight: bodyR, transform: nil))
    ctx.setFillColor(NSColor(white: 0.10, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: bodyR - 3, cornerHeight: bodyR - 3, transform: nil))
    ctx.setStrokeColor(NSColor(white: 0.42, alpha: 1).cgColor)
    ctx.setLineWidth(5)
    ctx.strokePath()
    // Screen.
    let scr = body.insetBy(dx: bezel, dy: bezel)
    let scrR = bodyR - bezel * 0.9
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: scr, cornerWidth: scrR, cornerHeight: scrR, transform: nil))
    ctx.clip()
    ctx.draw(screen, in: scr)
    // Status bar: time on the left, signal / Wi-Fi / battery on the right.
    let barY = scr.maxY - sw * 0.085
    NSAttributedString(string: "9:41", attributes: [.font: NSFont.systemFont(ofSize: sw * 0.044, weight: .semibold),
                                                    .foregroundColor: NSColor.white])
        .draw(at: NSPoint(x: scr.minX + sw * 0.12, y: barY - sw * 0.012))
    ctx.setFillColor(NSColor.white.cgColor)
    let bx = scr.maxX - sw * 0.27
    for i in 0..<4 {                                   // signal bars
        let bh = sw * (0.012 + CGFloat(i) * 0.006)
        ctx.fill(CGRect(x: bx + CGFloat(i) * sw * 0.014, y: barY, width: sw * 0.009, height: bh))
    }
    ctx.setStrokeColor(NSColor.white.cgColor)          // Wi-Fi arcs
    ctx.setLineWidth(sw * 0.006)
    ctx.setLineCap(.round)
    let wc = CGPoint(x: bx + sw * 0.092, y: barY + sw * 0.002)
    for r in [sw * 0.012, sw * 0.022] {
        ctx.addArc(center: wc, radius: r, startAngle: .pi * 0.25, endAngle: .pi * 0.75, clockwise: false)
        ctx.strokePath()
    }
    ctx.fillEllipse(in: CGRect(x: wc.x - sw * 0.004, y: wc.y - sw * 0.002, width: sw * 0.008, height: sw * 0.008))
    let batt = CGRect(x: bx + sw * 0.13, y: barY, width: sw * 0.058, height: sw * 0.027)
    ctx.addPath(CGPath(roundedRect: batt, cornerWidth: sw * 0.007, cornerHeight: sw * 0.007, transform: nil))
    ctx.setLineWidth(sw * 0.003)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
    ctx.strokePath()
    ctx.addPath(CGPath(roundedRect: batt.insetBy(dx: sw * 0.005, dy: sw * 0.005), cornerWidth: sw * 0.004, cornerHeight: sw * 0.004, transform: nil))
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    // Camera cutout pill.
    let pill = CGRect(x: scr.midX - sw * 0.16, y: scr.maxY - sw * 0.105, width: sw * 0.32, height: sw * 0.092)
    ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    // Home indicator.
    let home = CGRect(x: scr.midX - sw * 0.17, y: scr.minY + sw * 0.03, width: sw * 0.34, height: sw * 0.013)
    ctx.addPath(CGPath(roundedRect: home, cornerWidth: home.height / 2, cornerHeight: home.height / 2, transform: nil))
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    return rep.cgImage!
}

/// Phones side by side on a transparent background, for the README.
func phones(_ paths: [String], _ outPath: String) {
    let mocks = paths.map { phoneMock(cgImage($0)) }
    let h = 1000.0, gap = 70.0, pad = 60.0
    let widths = mocks.map { h * Double($0.width) / Double($0.height) }
    let W = Int(widths.reduce(0, +) + gap * Double(mocks.count - 1) + pad * 2), H = Int(h + pad * 2)
    let rep = bitmap(W, H)
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    var x = pad
    for (m, w) in zip(mocks, widths) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.draw(m, in: CGRect(x: x, y: pad, width: w, height: h))
        ctx.restoreGState()
        x += w + gap
    }
    NSGraphicsContext.current = nil
    save(rep, outPath)
    print("phones \(W)x\(H)")
}

let a = CommandLine.arguments
switch a[1] {
case "crop": crop(a[2], a[3])
case "banner": banner(a[2])
case "phone": let m = phoneMock(cgImage(a[2])); save(NSBitmapImageRep(cgImage: m), a[3])
case "phones": phones(Array(a[2..<(a.count - 1)]), a[a.count - 1])
default: print("usage: make-art crop <in> <out> | banner <out> | phone <in> <out> | phones <in>... <out>")
}
