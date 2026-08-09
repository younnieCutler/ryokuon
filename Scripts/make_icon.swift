import AppKit

// Renders Resources/AppIcon_1024.png — a cute rounded-gradient icon with a
// mic emoji, source for AppIcon.icns (built by Scripts/bundle.sh's icon
// step). Run standalone: `swift Scripts/make_icon.swift`.

let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let corner = CGFloat(size) * 0.22
let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
path.addClip()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.53, green: 0.86, blue: 0.78, alpha: 1), // mint
    NSColor(calibratedRed: 0.42, green: 0.68, blue: 0.92, alpha: 1), // soft blue
])
gradient?.draw(in: rect, angle: -60)

let emoji = "🎙️"
let font = NSFont.systemFont(ofSize: CGFloat(size) * 0.52)
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
let text = NSAttributedString(string: emoji, attributes: attributes)
let textSize = text.size()
let textRect = NSRect(x: (CGFloat(size) - textSize.width) / 2,
                       y: (CGFloat(size) - textSize.height) / 2 - CGFloat(size) * 0.03,
                       width: textSize.width, height: textSize.height)
text.draw(in: textRect)

image.unlockFocus()

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else { fatalError("failed to render icon") }

let outURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/AppIcon_1024.png")
try! png.write(to: outURL)
print("wrote \(outURL.path)")
