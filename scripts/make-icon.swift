// Renders AgentDeck's app icon into the asset catalog.
// Usage: swift scripts/make-icon.swift
import AppKit

let out = URL(fileURLWithPath: "AgentDeck/Assets.xcassets/AppIcon.appiconset")

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body, centered.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.20, green: 0.17, blue: 0.42, alpha: 1).cgColor,
        NSColor(red: 0.07, green: 0.07, blue: 0.14, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY), options: [])

    // Three stacked task cards, each with a status dot and progress bar.
    let cardW = body.width * 0.66, cardH = body.height * 0.17
    let x = body.midX - cardW / 2
    let colors: [NSColor] = [.systemGreen, .systemBlue, .systemOrange]
    let progress: [CGFloat] = [1.0, 0.62, 0.34]
    for i in 0..<3 {
        let y = body.midY + cardH * 0.95 - CGFloat(i) * cardH * 1.3 - cardH / 2
        let card = CGRect(x: x, y: y, width: cardW, height: cardH)
        let cp = CGPath(roundedRect: card, cornerWidth: cardH * 0.3, cornerHeight: cardH * 0.3, transform: nil)
        ctx.addPath(cp)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.13 + CGFloat(2 - i) * 0.04).cgColor)
        ctx.fillPath()
        ctx.addPath(cp)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(max(1, s * 0.003)); ctx.strokePath()

        let d = cardH * 0.36
        let dot = CGRect(x: card.minX + cardH * 0.32, y: card.midY - d / 2, width: d, height: d)
        ctx.setFillColor(colors[i].cgColor); ctx.fillEllipse(in: dot)

        let barX = dot.maxX + cardH * 0.3, barW = card.maxX - barX - cardH * 0.32, barH = cardH * 0.16
        let track = CGRect(x: barX, y: card.midY - barH / 2, width: barW, height: barH)
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.16).cgColor); ctx.fillPath()
        let fill = CGRect(x: barX, y: track.minY, width: barW * progress[i], height: barH)
        ctx.addPath(CGPath(roundedRect: fill, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil))
        ctx.setFillColor(colors[i].withAlphaComponent(0.95).cgColor); ctx.fillPath()
    }
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = "icon_\(pt)x\(pt)\(sc == 2 ? "@2x" : "").png"
        try! render(pt * sc).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "scale": "\(sc)x", "size": "\(pt)x\(pt)", "filename": name])
    }
}
let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icon images")
