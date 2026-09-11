// Generates the WiZard app icon (1024×1024 PNG) — glowing bulb on a dark
// squircle, matching the in-app bulb preview. Run once; output goes to
// /tmp/wizard-icon-1024.png, then build.sh turns it into AppIcon.icns.
import AppKit

let S: CGFloat = 1024
let image = NSImage(size: NSSize(width: S, height: S))
image.lockFocus()

func glow(center: NSPoint, radius: CGFloat, color: NSColor, maxAlpha: CGFloat, steps: Int = 64) {
    for i in (0..<steps).reversed() {
        let r = radius * CGFloat(i + 1) / CGFloat(steps)
        let a = maxAlpha * pow(1 - CGFloat(i) / CGFloat(steps), 2.2)
        color.withAlphaComponent(a).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)).fill()
    }
}

// Background squircle, dark night gradient — everything clips to it
let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: S, height: S), xRadius: 230, yRadius: 230)
NSGradient(colors: [NSColor(red: 0.15, green: 0.16, blue: 0.21, alpha: 1),
                    NSColor(red: 0.06, green: 0.06, blue: 0.09, alpha: 1)])?
    .draw(in: bg, angle: 270)
NSGraphicsContext.current?.saveGraphicsState()
bg.addClip()

let cx: CGFloat = 512
let glassCy: CGFloat = 596
let R: CGFloat = 218
let bulbColor = NSColor(red: 1.0, green: 0.85, blue: 0.32, alpha: 1)

// Diffused glow spilling from the glass
glow(center: NSPoint(x: cx, y: glassCy), radius: 470, color: bulbColor, maxAlpha: 0.42)

// Glass
let glass = NSBezierPath(ovalIn: NSRect(x: cx - R, y: glassCy - R, width: 2 * R, height: 2 * R))
if let g = NSGradient(colors: [NSColor(red: 1, green: 0.96, blue: 0.72, alpha: 1), bulbColor]) {
    g.draw(in: glass, angle: 270)
}

// Reflection: white fading from the top
NSGraphicsContext.current?.saveGraphicsState()
glass.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0)])?
    .draw(in: NSRect(x: cx - R, y: glassCy, width: 2 * R, height: R), angle: 270)
NSGraphicsContext.current?.restoreGraphicsState()

// Neck
let collarTop = glassCy - R - 16
let collarW: CGFloat = 240, collarH: CGFloat = 132
let neck = NSBezierPath()
neck.move(to: NSPoint(x: cx - collarW / 2 + 8, y: collarTop + 8))
neck.line(to: NSPoint(x: cx - R * 0.55, y: glassCy - R * 0.40))
neck.line(to: NSPoint(x: cx + R * 0.55, y: glassCy - R * 0.40))
neck.line(to: NSPoint(x: cx + collarW / 2 - 8, y: collarTop + 8))
neck.close()
bulbColor.setFill()
neck.fill()

// Collar (rounded bottom, square top)
let collarRect = NSRect(x: cx - collarW / 2, y: collarTop - collarH, width: collarW, height: collarH)
let collar = NSBezierPath()
collar.move(to: NSPoint(x: collarRect.minX, y: collarRect.maxY))
collar.line(to: NSPoint(x: collarRect.maxX, y: collarRect.maxY))
collar.line(to: NSPoint(x: collarRect.maxX, y: collarRect.minY + 52))
collar.appendArc(withCenter: NSPoint(x: collarRect.maxX - 52, y: collarRect.minY + 52),
                 radius: 52, startAngle: 0, endAngle: 270, clockwise: true)
collar.line(to: NSPoint(x: collarRect.minX + 52, y: collarRect.minY))
collar.appendArc(withCenter: NSPoint(x: collarRect.minX + 52, y: collarRect.minY + 52),
                 radius: 52, startAngle: 270, endAngle: 180, clockwise: true)
collar.close()
NSGradient(colors: [bulbColor, NSColor(red: 0.88, green: 0.66, blue: 0.16, alpha: 1)])?
    .draw(in: collar, angle: 270)

// Screw cap
let screwRect = NSRect(x: cx - 96, y: collarRect.minY + 18 - 130, width: 192, height: 130)
let screw = NSBezierPath()
screw.move(to: NSPoint(x: screwRect.minX, y: screwRect.maxY))
screw.line(to: NSPoint(x: screwRect.maxX, y: screwRect.maxY))
screw.line(to: NSPoint(x: screwRect.maxX, y: screwRect.minY + 58))
screw.appendArc(withCenter: NSPoint(x: screwRect.maxX - 58, y: screwRect.minY + 58),
                radius: 58, startAngle: 0, endAngle: 270, clockwise: true)
screw.line(to: NSPoint(x: screwRect.minX + 58, y: screwRect.minY))
screw.appendArc(withCenter: NSPoint(x: screwRect.minX + 58, y: screwRect.minY + 58),
                radius: 58, startAngle: 270, endAngle: 180, clockwise: true)
screw.close()
NSGradient(colors: [NSColor(calibratedWhite: 0.62, alpha: 1), NSColor(calibratedWhite: 0.42, alpha: 1)])?
    .draw(in: screw, angle: 270)

// Contact tip
let tip = NSBezierPath()
tip.move(to: NSPoint(x: cx - 48, y: screwRect.minY + 10))
tip.line(to: NSPoint(x: cx + 48, y: screwRect.minY + 10))
tip.line(to: NSPoint(x: cx + 26, y: screwRect.minY - 30))
tip.line(to: NSPoint(x: cx - 26, y: screwRect.minY - 30))
tip.close()
NSColor(calibratedWhite: 0.28, alpha: 1).setFill()
tip.fill()

NSGraphicsContext.current?.restoreGraphicsState()   // end squircle clip
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: "/tmp/wizard-icon-1024.png"))
print("icon written")
