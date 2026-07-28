// Renders the FlowBoard app icon: a waveform over a deep indigo→teal
// gradient. Run: swift scripts/make_icon.swift <output.png>
import AppKit

let size = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("bitmap")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.13, blue: 0.45, alpha: 1),
    NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.60, alpha: 1),
])!
gradient.draw(in: rect, angle: -60)

// Soft glow behind the wave
let glow = NSGradient(colors: [
    NSColor(calibratedWhite: 1, alpha: 0.16),
    NSColor(calibratedWhite: 1, alpha: 0),
])!
glow.draw(fromCenter: NSPoint(x: 512, y: 512), radius: 0,
          toCenter: NSPoint(x: 512, y: 512), radius: 480, options: [])

// Waveform bars
let weights: [CGFloat] = [0.28, 0.5, 0.78, 1.0, 0.66, 0.88, 0.46, 0.24]
let barWidth: CGFloat = 58
let gap: CGFloat = 34
let total = CGFloat(weights.count) * barWidth + CGFloat(weights.count - 1) * gap
var x = (CGFloat(size) - total) / 2
NSColor.white.setFill()
for weight in weights {
    let h = 560 * weight
    let bar = NSBezierPath(
        roundedRect: NSRect(x: x, y: (CGFloat(size) - h) / 2, width: barWidth, height: h),
        xRadius: barWidth / 2, yRadius: barWidth / 2)
    bar.fill()
    x += barWidth + gap
}

NSGraphicsContext.restoreGraphicsState()
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
