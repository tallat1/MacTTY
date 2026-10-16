// make-icon.swift: draws the MacTTY application icons.
//
//   swift macos/make-icon.swift macos/MacTTY.icns
//   swift macos/make-icon.swift macos/MacTTYgen.icns keygen
//   swift macos/make-icon.swift macos/Pageant.icns pageant
//
// A dark terminal with a green ">_" prompt and PuTTY's yellow lightning
// bolt as a nod to where it comes from. The key generator's terminal
// holds a key instead of the prompt; Pageant's key wears a top hat, after
// the pun in PuTTY's own Pageant icon. Geometry is on a 1024 grid, taken
// from the logo design (y measured from the top there, from the bottom
// here). At 64 px and below the details that would blur (outlines, the
// cursor, the hat band) are left out and the prompt is drawn bolder.
// The .icns files are committed; rerun this only when the design changes.

import AppKit

let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "mactty"

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

let baseTop = rgb(0x24344A), baseBottom = rgb(0x1D2A3A)
let screenFill = rgb(0x070B10), screenEdge = rgb(0x5B7086)
let green = rgb(0x34E06B)
let boltFill = rgb(0xFFC21A), boltEdge = rgb(0x7A4E00)

func path(_ pts: [(CGFloat, CGFloat)], _ s: CGFloat, closed: Bool) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: pts[0].0 * s, y: pts[0].1 * s))
    for q in pts.dropFirst() { p.line(to: NSPoint(x: q.0 * s, y: q.1 * s)) }
    if closed { p.close() }
    return p
}

// A key lying along the x axis, bow at the left, centred on (x, y) at
// the bow's left edge, with length l.
func drawKey(x: CGFloat, y: CGFloat, l: CGFloat, s: CGFloat) {
    let r = l * 0.22
    let key = NSBezierPath()
    key.appendOval(in: NSRect(x: x * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s))
    key.append(NSBezierPath(rect: NSRect(x: (x + 1.8 * r) * s, y: (y - r * 0.22) * s,
                                         width: (l - 1.8 * r) * s, height: r * 0.44 * s)))
    key.append(NSBezierPath(rect: NSRect(x: (x + l - r * 0.9) * s, y: (y - r * 0.85) * s,
                                         width: r * 0.32 * s, height: r * 0.7 * s)))
    key.append(NSBezierPath(rect: NSRect(x: (x + l - r * 0.35) * s, y: (y - r * 0.85) * s,
                                         width: r * 0.32 * s, height: r * 0.7 * s)))
    green.setFill()
    key.fill()
    // the hole in the bow
    screenFill.setFill()
    NSBezierPath(ovalIn: NSRect(x: (x + r * 0.55) * s, y: (y - r * 0.45) * s,
                                width: r * 0.9 * s, height: r * 0.9 * s)).fill()
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
    let detailed = size > 64

    // Rounded-square base, inset as Apple's icon grid expects.
    let base = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let basePath = NSBezierPath(roundedRect: base, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSGradient(starting: baseTop, ending: baseBottom)!.draw(in: basePath, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // The terminal screen.
    let screen = NSRect(x: 180 * s, y: 264 * s, width: 664 * s, height: 510 * s)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: 52 * s, yRadius: 52 * s)
    screenFill.setFill()
    screenPath.fill()
    if detailed {
        screenEdge.setStroke()
        screenPath.lineWidth = 12 * s
        screenPath.stroke()
    }

    if variant == "mactty" {
        // ">_": the chevron grows bolder as the icon gets smaller.
        let chevron = path([(268, 624), (388, 519), (268, 414)], s, closed: false)
        chevron.lineWidth = (size > 64 ? 58 : size > 32 ? 70 : size > 16 ? 84 : 100) * s
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        green.setStroke()
        chevron.stroke()
        if detailed {
            green.setFill()
            NSBezierPath(roundedRect: NSRect(x: 430 * s, y: 400 * s,
                                             width: 176 * s, height: 50 * s),
                         xRadius: 10 * s, yRadius: 10 * s).fill()
        }
    } else {
        drawKey(x: 232, y: 519, l: 330, s: s)
    }
    if variant == "pageant" {
        // A top hat on the key's bow.
        let hat = NSBezierPath()
        hat.append(NSBezierPath(roundedRect: NSRect(x: 190 * s, y: 597 * s,
                                                    width: 230 * s, height: 30 * s),
                                xRadius: 12 * s, yRadius: 12 * s))
        hat.append(NSBezierPath(rect: NSRect(x: 230 * s, y: 622 * s,
                                             width: 150 * s, height: 130 * s)))
        rgb(0x1A1A1F).setFill()
        hat.fill()
        rgb(0xBFC7D1).setStroke()
        hat.lineWidth = (detailed ? 8 : 16) * s
        hat.stroke()
        if detailed {
            rgb(0xCC1A1A).setFill()
            NSRect(x: 234 * s, y: 637 * s, width: 142 * s, height: 26 * s).fill()
        }
    }

    // Lightning bolt.
    let bolt = path([(702, 874), (572, 554), (678, 554), (556, 204),
                     (846, 632), (732, 632), (828, 874)], s, closed: true)
    boltFill.setFill()
    bolt.fill()
    if detailed {
        boltEdge.setStroke()
        bolt.lineWidth = 14 * s
        bolt.lineJoinStyle = .round
        bolt.stroke()
    }

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
