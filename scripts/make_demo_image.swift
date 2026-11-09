// Draws the picture embedded in the demo winmail.dat: a space-bar keycap
// with a caption, as a 2x (144 dpi) PNG. Usage: swift scripts/make_demo_image.swift <output.png>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make_demo_image.swift <output.png>\n".utf8))
    exit(2)
}

// The drawing below uses a 1720 x 520 layout, scaled down to the output size.
// The PNG is saved at 144 dpi, so it is shown at half its pixel size (573 points).
let layoutWidth: CGFloat = 1720
let width = 1146, height = 346
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let transform = NSAffineTransform()
transform.scale(by: CGFloat(width) / layoutWidth)
transform.concat()
let canvas = NSRect(x: 0, y: 0, width: 1720, height: 520)

// background
NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.55, blue: 0.98, alpha: 1),
                    NSColor(srgbRed: 0.58, green: 0.38, blue: 0.94, alpha: 1)])!
    .draw(in: NSBezierPath(roundedRect: canvas, xRadius: 36, yRadius: 36), angle: -18)

// keycap with shadow
let key = NSRect(x: 150, y: 150, width: 820, height: 220)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.shadowBlurRadius = 28
shadow.set()
NSColor(white: 0.97, alpha: 1).setFill()
NSBezierPath(roundedRect: key, xRadius: 34, yRadius: 34).fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(white: 0.9, alpha: 1)])!
    .draw(in: NSBezierPath(roundedRect: key.insetBy(dx: 16, dy: 16), xRadius: 24, yRadius: 24), angle: -90)

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, in rect: NSRect, align: NSTextAlignment) {
    let style = NSMutableParagraphStyle()
    style.alignment = align
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: style,
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let textHeight = string.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin]).height
    string.draw(in: NSRect(x: rect.minX, y: rect.midY - textHeight / 2, width: rect.width, height: textHeight))
}

draw("space", size: 78, weight: .medium, color: NSColor(white: 0.35, alpha: 1), in: key, align: .center)
draw("to peek inside\nwinmail.dat", size: 76, weight: .bold, color: .white,
     in: NSRect(x: 1040, y: 60, width: 640, height: 400), align: .left)

NSGraphicsContext.restoreGraphicsState()
bitmap.size = NSSize(width: width / 2, height: height / 2) // 144 dpi
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: arguments[1]))
