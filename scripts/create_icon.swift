import AppKit
import CoreGraphics

let size = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/AppIcon.png"
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                  bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let canvas = context.cgContext
canvas.setAllowsAntialiasing(true)
canvas.setShouldAntialias(true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, a])!
}

let tile = CGPath(roundedRect: CGRect(x: 40, y: 40, width: 944, height: 944),
                  cornerWidth: 220, cornerHeight: 220, transform: nil)
canvas.saveGState()
canvas.addPath(tile)
canvas.clip()
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(0.025, 0.30, 0.24), color(0.055, 0.65, 0.44)] as CFArray,
                          locations: [0, 1])!
canvas.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 40),
                          end: CGPoint(x: 900, y: 984), options: [])
canvas.setFillColor(color(1, 1, 1, 0.08))
canvas.fillEllipse(in: CGRect(x: -120, y: 380, width: 760, height: 760))
canvas.restoreGState()

let white = color(1, 1, 1, 0.94)
canvas.setStrokeColor(white)
canvas.setLineWidth(28)
canvas.strokeEllipse(in: CGRect(x: 238, y: 240, width: 548, height: 548))
canvas.setLineWidth(22)
canvas.strokeEllipse(in: CGRect(x: 374, y: 240, width: 276, height: 548))
let globe = CGPath(ellipseIn: CGRect(x: 238, y: 240, width: 548, height: 548), transform: nil)
canvas.saveGState()
canvas.addPath(globe)
canvas.clip()
for y in [424.0, 605.0] {
    canvas.move(to: CGPoint(x: 220, y: y))
    canvas.addLine(to: CGPoint(x: 804, y: y))
    canvas.strokePath()
}
canvas.restoreGState()

// A small connected badge keeps the icon legible in the Dock and Finder.
canvas.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0, 0.16, 0.13, 0.35))
canvas.setFillColor(color(0.80, 0.99, 0.90))
canvas.fillEllipse(in: CGRect(x: 625, y: 152, width: 240, height: 240))
canvas.setShadow(offset: .zero, blur: 0)
canvas.setStrokeColor(color(0.04, 0.48, 0.34))
canvas.setLineWidth(30)
canvas.setLineCap(.round)
canvas.setLineJoin(.round)
canvas.move(to: CGPoint(x: 684, y: 267))
canvas.addLine(to: CGPoint(x: 730, y: 220))
canvas.addLine(to: CGPoint(x: 810, y: 316))
canvas.strokePath()

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode PNG") }
try png.write(to: URL(fileURLWithPath: output))
