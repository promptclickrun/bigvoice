import AppKit
import Foundation

// App icon from the V2 spec: the listening mark in Signal on an ink squircle, with the inset
// top highlight and hairline edge. Drawn on Apple's 1024 grid (824 pt body, 185 pt radius).
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift GenerateIcon.swift <iconset-directory>")
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let ink = color(0x0E0C0A), signal = color(0xFF8D39)
let warmLine = { (alpha: CGFloat) in CGColor(srgbRed: 1, green: 240.0 / 255, blue: 220.0 / 255, alpha: alpha) }
let profile: [CGFloat] = [0.42, 0.7, 1, 0.78, 0.5]

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("context") }
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.42))
        context.addPath(squircle)
        context.setFillColor(ink)
        context.fillPath()
        context.restoreGState()

        // Inset top highlight fading down the edge, then the hairline ring.
        context.saveGState()
        context.addPath(CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: 182, cornerHeight: 182, transform: nil))
        context.setLineWidth(6)
        context.replacePathWithStrokedPath()
        context.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [warmLine(0.16), warmLine(0.0)] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.maxY - 300), options: [])
        context.restoreGState()
        context.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
        context.setStrokeColor(warmLine(0.08))
        context.setLineWidth(4)
        context.strokePath()

        // The listening mark: bar .11 · gap .085 of the mark size (53.6% of the body, per spec).
        let small = pixels <= 64
        let mark = 824 * 0.536
        let width = mark * 0.11 * (small ? 1.45 : 1), gap = mark * 0.085 * (small ? 0.78 : 1)
        let x0 = 512 - (5 * width + 4 * gap) / 2
        context.setFillColor(signal)
        for (index, value) in profile.enumerated() {
            let height = mark * 0.9 * value
            let rect = CGRect(x: x0 + CGFloat(index) * (width + gap), y: 512 - height / 2, width: width, height: height)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
            context.fillPath()
        }

        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("encode") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
