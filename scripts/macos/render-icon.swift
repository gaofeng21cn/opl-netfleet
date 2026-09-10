import AppKit

// Dock artwork has an optical safe area; keep the canonical logo bytes intact.
let arguments = CommandLine.arguments
let source = NSImage(contentsOfFile: arguments[1])!
let pixels = Int(arguments[3])!
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
let edge = CGFloat(pixels) * 0.82
let inset = (CGFloat(pixels) - edge) / 2
source.draw(in: NSRect(x: inset, y: inset, width: edge, height: edge),
            from: .zero, operation: .copy, fraction: 1)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
