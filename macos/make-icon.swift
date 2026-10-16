// make-icon.swift: draws the MacTTY application icons.
//
//   swift macos/make-icon.swift macos/MacTTY.icns
//   swift macos/make-icon.swift macos/MacTTYgen.icns keygen
//   swift macos/make-icon.swift macos/Pageant.icns pageant
//
// A dark terminal with a green prompt and PuTTY's yellow lightning bolt
// as a nod to where it comes from. The key generator's terminal holds a
// key instead of the prompt; Pageant's key wears a top hat, after the
// pun in PuTTY's own Pageant icon. The .icns files are committed; rerun
// this only when the design changes.

import AppKit

let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "mactty"

// A key lying along the x axis, bow at the left, at (x, y) with length l.
func drawKey(x: CGFloat, y: CGFloat, l: CGFloat, s: CGFloat) {
    let gold = NSColor(srgbRed: 1.0, green: 0.80, blue: 0.0, alpha: 1)
    let edge = NSColor(srgbRed: 0.55, green: 0.38, blue: 0.0, alpha: 1)
    let r = l * 0.22
    let key = NSBezierPath()
    key.appendOval(in: NSRect(x: x, y: y - r, width: 2 * r, height: 2 * r))
    key.append(NSBezierPath(rect: NSRect(x: x + 1.8 * r, y: y - r * 0.22,
                                         width: l - 1.8 * r, height: r * 0.44)))
    key.append(NSBezierPath(rect: NSRect(x: x + l - r * 0.9, y: y - r * 0.85,
                                         width: r * 0.32, height: r * 0.7)))
    key.append(NSBezierPath(rect: NSRect(x: x + l - r * 0.35, y: y - r * 0.85,
                                         width: r * 0.32, height: r * 0.7)))
    gold.setFill()
    key.fill()
    edge.setStroke()
    key.lineWidth = 10 * s
    key.stroke()
    // the hole in the bow
    NSColor(srgbRed: 0.02, green: 0.03, blue: 0.04, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: x + r * 0.55, y: y - r * 0.45,
                                width: r * 0.9, height: r * 0.9)).fill()
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size),
                               pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Squircle-ish base, inset as Apple's icon grid expects.
    let base = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let basePath = NSBezierPath(roundedRect: base, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.27, blue: 0.36, alpha: 1),
               ending: NSColor(srgbRed: 0.07, green: 0.10, blue: 0.14, alpha: 1))!
        .draw(in: basePath, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // The terminal screen.
    let screen = NSRect(x: 180 * s, y: 230 * s, width: 664 * s, height: 520 * s)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: 48 * s, yRadius: 48 * s)
    NSColor(srgbRed: 0.02, green: 0.03, blue: 0.04, alpha: 1).setFill()
    screenPath.fill()
    NSColor(srgbRed: 0.45, green: 0.55, blue: 0.65, alpha: 0.6).setStroke()
    screenPath.lineWidth = 10 * s
    screenPath.stroke()

    if variant == "mactty" {
        // ">_" prompt in PuTTY's cursor green.
        let green = NSColor(srgbRed: 0.0, green: 1.0, blue: 0.0, alpha: 1)
        let font = NSFont.monospacedSystemFont(ofSize: 250 * s, weight: .bold)
        NSAttributedString(string: ">", attributes: [.font: font, .foregroundColor: green])
            .draw(at: NSPoint(x: 240 * s, y: 330 * s))
        green.setFill()
        NSRect(x: 420 * s, y: 360 * s, width: 150 * s, height: 34 * s).fill()
    } else {
        drawKey(x: 200 * s, y: 430 * s, l: 330 * s, s: s)
    }
    if variant == "pageant" {
        // A top hat on the key's bow.
        let hat = NSBezierPath()
        hat.append(NSBezierPath(roundedRect: NSRect(x: 158 * s, y: 508 * s,
                                                    width: 230 * s, height: 30 * s),
                                xRadius: 12 * s, yRadius: 12 * s))
        hat.append(NSBezierPath(rect: NSRect(x: 198 * s, y: 533 * s,
                                             width: 150 * s, height: 150 * s)))
        NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1).setFill()
        hat.fill()
        NSColor(srgbRed: 0.75, green: 0.78, blue: 0.82, alpha: 1).setStroke()
        hat.lineWidth = 8 * s
        hat.stroke()
        NSColor(srgbRed: 0.80, green: 0.10, blue: 0.10, alpha: 1).setFill()
        NSRect(x: 202 * s, y: 548 * s, width: 142 * s, height: 26 * s).fill()
    }

    // Lightning bolt.
    let bolt = NSBezierPath()
    let pts: [(CGFloat, CGFloat)] = [(700, 900), (560, 600), (660, 610),
                                     (540, 330), (800, 680), (690, 670),
                                     (800, 900)]
    bolt.move(to: NSPoint(x: pts[0].0 * s, y: pts[0].1 * s))
    for p in pts.dropFirst() { bolt.line(to: NSPoint(x: p.0 * s, y: p.1 * s)) }
    bolt.close()
    NSColor(srgbRed: 1.0, green: 0.80, blue: 0.0, alpha: 1).setFill()
    bolt.fill()
    NSColor(srgbRed: 0.55, green: 0.38, blue: 0.0, alpha: 1).setStroke()
    bolt.lineWidth = 12 * s
    bolt.lineJoinStyle = .round
    bolt.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "MacTTY.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("MacTTY-\(getpid()).iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = drawIcon(size: px).representation(using: .png, properties: [:])!
        try! data.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(task.terminationStatus)
