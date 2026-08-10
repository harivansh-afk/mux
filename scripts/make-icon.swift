// Renders the mux app icon: a dark rounded-square terminal split BSP-style,
// cream dividers and border on near-black - the app's own palette (accent
// #EBDBB2 on panelBg #101010), monotone. "The UI is the panes."
//
// Usage: swift scripts/make-icon.swift <output-iconset-dir>
// Emits the ten icon_<n>x<n>[@2x].png files an .icns needs; a caller runs
// `iconutil -c icns` over the directory.

import AppKit

let bg = NSColor(srgbRed: 0x10 / 255, green: 0x10 / 255, blue: 0x10 / 255, alpha: 1)
let ink = NSColor(srgbRed: 0xEB / 255, green: 0xDB / 255, blue: 0xB2 / 255, alpha: 1)

/// Draw the icon into a `side`x`side` bitmap and return its PNG data.
func render(side: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // The squircle sits inside ~9% padding, like Apple's icon grid.
    let pad = side * 0.09
    let box = NSRect(x: pad, y: pad, width: side - pad * 2, height: side - pad * 2)
    let radius = box.width * 0.2237 // Apple's continuous-corner ratio
    let squircle = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)

    bg.setFill()
    squircle.fill()

    // Strokes stay legible from 16px to 1024px: bold, clamped.
    let stroke = max(1, side * 0.045)
    ink.setStroke()

    // Border: inset by half the stroke so it lands fully inside the squircle.
    let inset = box.insetBy(dx: stroke / 2, dy: stroke / 2)
    let border = NSBezierPath(
        roundedRect: inset,
        xRadius: radius - stroke / 2, yRadius: radius - stroke / 2
    )
    border.lineWidth = stroke
    border.stroke()

    // Clip interior strokes to the squircle so nothing overshoots the corners.
    squircle.setClip()

    // BSP split: vertical divider at 45%, right column halved. Endpoints butt
    // into the inner border line (inset by one stroke) so the dividers connect
    // to the frame cleanly instead of poking round caps through it.
    let splitX = box.minX + box.width * 0.45
    let innerLo = box.minY + stroke
    let innerHi = box.maxY - stroke
    let vertical = NSBezierPath()
    vertical.move(to: NSPoint(x: splitX, y: innerLo))
    vertical.line(to: NSPoint(x: splitX, y: innerHi))
    vertical.lineWidth = stroke
    vertical.lineCapStyle = .butt
    vertical.stroke()

    let horizontal = NSBezierPath()
    horizontal.move(to: NSPoint(x: splitX, y: box.midY))
    horizontal.line(to: NSPoint(x: box.maxX - stroke, y: box.midY))
    horizontal.lineWidth = stroke
    horizontal.lineCapStyle = .butt
    horizontal.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <iconset-dir>\n".utf8))
    exit(2)
}
let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(
    atPath: outDir, withIntermediateDirectories: true
)

// (point size, @2x?) -> filename, per the .icns iconset convention.
let variants: [(pt: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
    (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]
for v in variants {
    let px = v.pt * v.scale
    let name = v.scale == 2 ? "icon_\(v.pt)x\(v.pt)@2x.png" : "icon_\(v.pt)x\(v.pt).png"
    let data = render(side: CGFloat(px))
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}
print("wrote \(variants.count) icons to \(outDir)")
